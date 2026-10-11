// Runnable check for OpenParsec/audio.c ring logic (macOS host):
//   clang -framework AudioToolbox scripts/audio-ring-check.c -o /tmp/arc && /tmp/arc
#include "../OpenParsec/audio.c"
#include <assert.h>
#include <stdio.h>
#include <unistd.h>

static int16_t out[BUF_FRAMES * CHANNELS];
static struct AudioQueueBuffer qb = { .mAudioDataBytesCapacity = sizeof(out), .mAudioData = out };

static void push(struct audio *ctx, int start, int frames) {
	int16_t *pcm = malloc(frames * CHANNELS * sizeof(int16_t));
	for (int i = 0; i < frames; i++) { pcm[i * 2] = (int16_t)(start + i); pcm[i * 2 + 1] = (int16_t)-(start + i); }
	audio_cb(pcm, frames, ctx);
	free(pcm);
}

int main(void) {
	struct audio *ctx;
	audio_init(&ctx);
	ctx->retry_skip = INT32_MAX;   // test the ring only: no real AudioQueue pulling concurrently

	// Prebuffer: below the 40 ms starting cushion nothing plays.
	assert(ctx->target == TARGET_MIN_FRAMES);
	push(ctx, 1, 1440);
	fill(ctx, &qb);
	assert(out[0] == 0 && qb.mAudioDataByteSize == sizeof(out));

	// Ordered playback once the cushion is reached.
	push(ctx, 1441, 480);
	fill(ctx, &qb);
	assert(out[0] == 1 && out[1] == -1 && out[(BUF_FRAMES - 1) * 2] == 480);
	fill(ctx, &qb);
	assert(out[0] == 481);
	fill(ctx, &qb);
	fill(ctx, &qb);
	assert(out[0] == 1441 && ctx->count == 0 && ctx->playing);

	// Underrun (partial/empty buffer) is silence and grows the cushion +20 ms.
	fill(ctx, &qb);
	assert(out[0] == 0 && out[(BUF_FRAMES - 1) * 2] == 0);
	assert(!ctx->playing && ctx->target == TARGET_MIN_FRAMES + TARGET_STEP_UP);

	// Growth is capped at 120 ms.
	for (int i = 0; i < 10; i++) ctx->target = next_target(ctx->target, true);
	assert(ctx->target == TARGET_MAX_FRAMES);
	// Clean playback shrinks it, never below 40 ms.
	for (int i = 0; i < 20; i++) ctx->target = next_target(ctx->target, false);
	assert(ctx->target == TARGET_MIN_FRAMES);

	// 10 s of full buffers shrinks the target by 10 ms.
	audio_clear(&ctx);
	ctx->retry_skip = INT32_MAX;
	ctx->target = TARGET_MIN_FRAMES + TARGET_STEP_UP;
	push(ctx, 0, ctx->target);
	for (int i = 0; i < CLEAN_FILLS_TO_SHRINK; i++) {
		push(ctx, i, BUF_FRAMES);
		fill(ctx, &qb);
	}
	assert(ctx->target == TARGET_MIN_FRAMES + TARGET_STEP_UP - TARGET_STEP_DOWN);

	// Latency cap keeps only the newest target + 100 ms.
	audio_clear(&ctx);
	ctx->retry_skip = INT32_MAX;
	push(ctx, 1000, 20000);
	assert(ctx->count == ctx->target + LATENCY_SLACK_FRAMES);
	fill(ctx, &qb);
	assert(out[0] == (int16_t)(1000 + 20000 - ctx->target - LATENCY_SLACK_FRAMES));

	// Wrap-around across the ring end stays in order.
	audio_clear(&ctx);
	ctx->retry_skip = INT32_MAX;
	for (int i = 0; i < 60; i++) {
		push(ctx, i * 480, 480);
		fill(ctx, &qb);
	}
	push(ctx, 60 * 480, 480);
	fill(ctx, &qb);
	for (int i = 1; i < BUF_FRAMES; i++) assert((int16_t)(out[i * 2] - out[(i - 1) * 2]) == 1);

	// Mute drops host audio.
	audio_mute(true, ctx);
	push(ctx, 7, 2000);
	assert(ctx->count == 0);
	audio_mute(false, ctx);

	// Live queue on this Mac: audio_start creates it and it reports running
	// after the 1 s settle window (needs an audio output device).
	if (getenv("CI") == NULL) {    // CI runners have no audio output device
		audio_clear(&ctx);
		audio_start(ctx);
		usleep(1500000);
		assert(audio_is_running(ctx));
	}

	audio_destroy(&ctx);
	puts("audio-ring-check: ok");
	return 0;
}
