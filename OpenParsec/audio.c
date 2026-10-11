#include "audio.h"

#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <os/lock.h>
#include <time.h>

#include <AudioToolbox/AudioToolbox.h>

// ponytail: pull-model player. The SDK poll thread pushes PCM into a locked
// ring; the AudioQueue keeps NUM_BUFS buffers in flight and refills each one
// from the ring, or with silence on underrun, so playback never depends on the
// producer restarting it. Any failure (interruption, media-services reset,
// start refused while the session is inactive) is handled by disposing the
// queue; the next audio packet lazily recreates it.

#define CHANNELS 2
#define RATE 48000
#define BUF_FRAMES 480                 // 10 ms per AudioQueue buffer
#define NUM_BUFS 3
#define RING_FRAMES (RATE / 2)         // 500 ms capacity
#define TARGET_MIN_FRAMES 1920         // 40 ms starting / minimum jitter cushion
#define TARGET_MAX_FRAMES 5760         // 120 ms ceiling on a very jittery link
#define TARGET_STEP_UP 960             // +20 ms per audible underrun
#define TARGET_STEP_DOWN 480           // -10 ms per 10 s without underruns
#define CLEAN_FILLS_TO_SHRINK 1000     // 1000 x 10 ms buffers = 10 s
#define LATENCY_SLACK_FRAMES 4800      // drop audio older than target + 100 ms (drift / burst after stall)
#define RETRY_SKIP_PACKETS 50          // ~0.5 s between queue re-creation attempts

struct audio {
	pthread_mutex_t qlock;             // guards q lifecycle
	AudioQueueRef q;
	int32_t retry_skip;
	uint64_t created_ns;               // CLOCK_UPTIME_RAW at queue creation

	os_unfair_lock lock;               // guards the ring and flags below
	int16_t ring[RING_FRAMES * CHANNELS];
	uint32_t head;                     // read position, frames
	uint32_t count;                    // buffered frames
	bool playing;                      // false while prebuffering
	uint32_t target;                   // adaptive jitter cushion, frames
	uint32_t clean_fills;              // full buffers played since the last underrun
	bool muted;
};

// ponytail: adaptive jitter buffer. The SDK keeps ~1 audio frame, so this ring
// is the only cushion: grow on every audible underrun, shrink slowly while the
// link is clean. Ceiling 120 ms keeps lip-sync acceptable.
static uint32_t next_target(uint32_t target, bool underrun)
{
	if (underrun)
		return target + TARGET_STEP_UP > TARGET_MAX_FRAMES ? TARGET_MAX_FRAMES : target + TARGET_STEP_UP;
	return target >= TARGET_MIN_FRAMES + TARGET_STEP_DOWN ? target - TARGET_STEP_DOWN : TARGET_MIN_FRAMES;
}

static void fill(struct audio *ctx, AudioQueueBufferRef b)
{
	int16_t *out = (int16_t *) b->mAudioData;
	uint32_t n = 0;

	os_unfair_lock_lock(&ctx->lock);
	if (!ctx->playing && ctx->count >= ctx->target)
		ctx->playing = true;
	if (ctx->playing) {
		n = ctx->count < BUF_FRAMES ? ctx->count : BUF_FRAMES;
		uint32_t first = RING_FRAMES - ctx->head;
		if (first > n) first = n;
		memcpy(out, &ctx->ring[ctx->head * CHANNELS], first * CHANNELS * sizeof(int16_t));
		memcpy(out + first * CHANNELS, ctx->ring, (n - first) * CHANNELS * sizeof(int16_t));
		ctx->head = (ctx->head + n) % RING_FRAMES;
		ctx->count -= n;
		if (n < BUF_FRAMES) {          // audible gap: rebuild a larger cushion first
			ctx->playing = false;
			ctx->target = next_target(ctx->target, true);
			ctx->clean_fills = 0;
		} else if (++ctx->clean_fills >= CLEAN_FILLS_TO_SHRINK) {
			ctx->target = next_target(ctx->target, false);
			ctx->clean_fills = 0;
		}
	}
	os_unfair_lock_unlock(&ctx->lock);

	memset(out + n * CHANNELS, 0, (BUF_FRAMES - n) * CHANNELS * sizeof(int16_t));
	b->mAudioDataByteSize = BUF_FRAMES * CHANNELS * sizeof(int16_t);
}

static void audio_queue_callback(void *opaque, AudioQueueRef queue, AudioQueueBufferRef buffer)
{
	fill((struct audio *) opaque, buffer);
	AudioQueueEnqueueBuffer(queue, buffer, 0, NULL);
}

// Caller holds qlock.
static void destroy_queue(struct audio *ctx)
{
	if (ctx->q == NULL) return;
	AudioQueueDispose(ctx->q, true);   // synchronous: waits for an in-flight callback
	ctx->q = NULL;
}

// Caller holds qlock.
static bool queue_is_running(struct audio *ctx)
{
	if (ctx->q == NULL) return false;
	UInt32 running = 0;
	UInt32 size = sizeof(running);
	if (AudioQueueGetProperty(ctx->q, kAudioQueueProperty_IsRunning, &running, &size) != noErr)
		return false;
	return running != 0;
}

// AudioQueueStart is asynchronous, so IsRunning is only trusted ~1 s after
// creation. Time-based: a silent host delivers no packets to count.
static bool queue_settled(struct audio *ctx)
{
	return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - ctx->created_ns > 1000000000ULL;
}

static void ensure_running(struct audio *ctx, bool force);

// Caller holds qlock.
static void create_queue(struct audio *ctx)
{
	AudioStreamBasicDescription format = {0};
	format.mSampleRate = RATE;
	format.mFormatID = kAudioFormatLinearPCM;
	format.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
	format.mFramesPerPacket = 1;
	format.mChannelsPerFrame = CHANNELS;
	format.mBitsPerChannel = 16;
	format.mBytesPerFrame = CHANNELS * sizeof(int16_t);
	format.mBytesPerPacket = format.mBytesPerFrame;

	if (AudioQueueNewOutput(&format, audio_queue_callback, ctx, NULL, NULL, 0, &ctx->q) != noErr) {
		ctx->q = NULL;
		return;
	}
	for (int i = 0; i < NUM_BUFS; i++) {
		AudioQueueBufferRef b;
		if (AudioQueueAllocateBuffer(ctx->q, BUF_FRAMES * format.mBytesPerFrame, &b) != noErr) {
			destroy_queue(ctx);
			return;
		}
		fill(ctx, b);
		AudioQueueEnqueueBuffer(ctx->q, b, 0, NULL);
	}
	ctx->created_ns = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
	if (AudioQueueStart(ctx->q, NULL) != noErr)
		destroy_queue(ctx);            // e.g. session inactive/interrupted; retried later
}

static void reset_ring(struct audio *ctx)
{
	os_unfair_lock_lock(&ctx->lock);
	ctx->head = 0;
	ctx->count = 0;
	ctx->playing = false;
	os_unfair_lock_unlock(&ctx->lock);
}

void audio_init(struct audio **ctx_out)
{
	struct audio *ctx = *ctx_out = calloc(1, sizeof(struct audio));
	pthread_mutex_init(&ctx->qlock, NULL);
	ctx->lock = OS_UNFAIR_LOCK_INIT;
	ctx->target = TARGET_MIN_FRAMES;
}

void audio_destroy(struct audio **ctx_out)
{
	if (!ctx_out || !*ctx_out)
		return;
	struct audio *ctx = *ctx_out;
	pthread_mutex_lock(&ctx->qlock);
	destroy_queue(ctx);
	pthread_mutex_unlock(&ctx->qlock);
	pthread_mutex_destroy(&ctx->qlock);
	free(ctx);
	*ctx_out = NULL;
}

// Stops playback and drops buffered audio. The next packet recreates the
// queue, so this is also the recovery path after interruptions and resets.
void audio_clear(struct audio **ctx_out)
{
	if (!ctx_out || !*ctx_out)
		return;
	struct audio *ctx = *ctx_out;
	pthread_mutex_lock(&ctx->qlock);
	destroy_queue(ctx);
	ctx->retry_skip = 0;
	pthread_mutex_unlock(&ctx->qlock);
	reset_ring(ctx);
	os_unfair_lock_lock(&ctx->lock);
	ctx->target = TARGET_MIN_FRAMES;   // each session re-learns its jitter cushion
	ctx->clean_fills = 0;
	os_unfair_lock_unlock(&ctx->lock);
}

void audio_cb(const int16_t *pcm, uint32_t frames, void *opaque)
{
	struct audio *ctx = (struct audio *) opaque;
	if (ctx == NULL || pcm == NULL || frames == 0)
		return;

	os_unfair_lock_lock(&ctx->lock);
	if (!ctx->muted) {
		if (frames > RING_FRAMES) {    // keep only the newest audio
			pcm += (frames - RING_FRAMES) * CHANNELS;
			frames = RING_FRAMES;
		}
		uint32_t tail = (ctx->head + ctx->count) % RING_FRAMES;
		uint32_t first = RING_FRAMES - tail;
		if (first > frames) first = frames;
		memcpy(&ctx->ring[tail * CHANNELS], pcm, first * CHANNELS * sizeof(int16_t));
		memcpy(ctx->ring, pcm + first * CHANNELS, (frames - first) * CHANNELS * sizeof(int16_t));
		ctx->count += frames;
		if (ctx->count > ctx->target + LATENCY_SLACK_FRAMES) {
			uint32_t drop = ctx->count - (ctx->target + LATENCY_SLACK_FRAMES);
			ctx->head = (ctx->head + drop) % RING_FRAMES;
			ctx->count -= drop;
		}
	}
	os_unfair_lock_unlock(&ctx->lock);

	ensure_running(ctx, false);
}

// Recreates the queue when it is missing or was stopped by the system
// (interruption, media-services reset). Rate-limited unless forced.
static void ensure_running(struct audio *ctx, bool force)
{
	pthread_mutex_lock(&ctx->qlock);
	if (force)
		ctx->retry_skip = 0;
	if (ctx->q != NULL && queue_settled(ctx) && !queue_is_running(ctx))
		destroy_queue(ctx);
	if (ctx->q == NULL) {
		if (ctx->retry_skip > 0) {
			ctx->retry_skip--;
		} else {
			create_queue(ctx);
			if (ctx->q == NULL)
				ctx->retry_skip = RETRY_SKIP_PACKETS;
		}
	}
	pthread_mutex_unlock(&ctx->qlock);
}

void audio_start(const void *opaque)
{
	if (opaque == NULL) return;
	ensure_running((struct audio *) opaque, true);
}

bool audio_is_running(const void *opaque)
{
	struct audio *ctx = (struct audio *) opaque;
	if (ctx == NULL) return false;
	pthread_mutex_lock(&ctx->qlock);
	bool running = ctx->q != NULL && (!queue_settled(ctx) || queue_is_running(ctx));
	pthread_mutex_unlock(&ctx->qlock);
	return running;
}

// Muting keeps the queue playing silence so the background keep-alive and
// the audio route survive; only the host audio is dropped.
void audio_mute(bool muted, const void *opaque)
{
	struct audio *ctx = (struct audio *) opaque;
	if (ctx == NULL) return;
	os_unfair_lock_lock(&ctx->lock);
	ctx->muted = muted;
	if (muted) {
		ctx->head = 0;
		ctx->count = 0;
		ctx->playing = false;
	}
	os_unfair_lock_unlock(&ctx->lock);
}
