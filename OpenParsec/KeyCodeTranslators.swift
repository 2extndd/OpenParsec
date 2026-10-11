import UIKit

class KeyCodeTranslators {
	static func uiKeyCodeToInt(key: UIKeyboardHIDUsage) -> Int {
		switch key {
		case .keyboardErrorRollOver:
			return 1
		case .keyboardPOSTFail:
			return 2
		case .keyboardErrorUndefined:
			return 3
		case .keyboardA:
			return 4
		case .keyboardB:
			return 5
		case .keyboardC:
			return 6
		case .keyboardD:
			return 7
		case .keyboardE:
			return 8
		case .keyboardF:
			return 9
		case .keyboardG:
			return 10
		case .keyboardH:
			return 11
		case .keyboardI:
			return 12
		case .keyboardJ:
			return 13
		case .keyboardK:
			return 14
		case .keyboardL:
			return 15
		case .keyboardM:
			return 16
		case .keyboardN:
			return 17
		case .keyboardO:
			return 18
		case .keyboardP:
			return 19
		case .keyboardQ:
			return 20
		case .keyboardR:
			return 21
		case .keyboardS:
			return 22
		case .keyboardT:
			return 23
		case .keyboardU:
			return 24
		case .keyboardV:
			return 25
		case .keyboardW:
			return 26
		case .keyboardX:
			return 27
		case .keyboardY:
			return 28
		case .keyboardZ:
			return 29
		case .keyboard1:
			return 30
		case .keyboard2:
			return 31
		case .keyboard3:
			return 32
		case .keyboard4:
			return 33
		case .keyboard5:
			return 34
		case .keyboard6:
			return 35
		case .keyboard7:
			return 36
		case .keyboard8:
			return 37
		case .keyboard9:
			return 38
		case .keyboard0:
			return 39
		case .keyboardReturnOrEnter:
			return 40
		case .keyboardEscape:
			return 41
		case .keyboardDeleteOrBackspace:
			return 42
		case .keyboardTab:
			return 43
		case .keyboardSpacebar:
			return 44
		case .keyboardHyphen:
			return 45
		case .keyboardEqualSign:
			return 46
		case .keyboardOpenBracket:
			return 47
		case .keyboardCloseBracket:
			return 48
		case .keyboardBackslash:
			return 49
		case .keyboardNonUSPound:
			return 50
		case .keyboardSemicolon:
			return 51
		case .keyboardQuote:
			return 52
		case .keyboardGraveAccentAndTilde:
			return 53
		case .keyboardComma:
			return 54
		case .keyboardPeriod:
			return 55
		case .keyboardSlash:
			return 56
		case .keyboardCapsLock:
			return 57
		case .keyboardF1:
			return 58
		case .keyboardF2:
			return 59
		case .keyboardF3:
			return 60
		case .keyboardF4:
			return 61
		case .keyboardF5:
			return 62
		case .keyboardF6:
			return 63
		case .keyboardF7:
			return 64
		case .keyboardF8:
			return 65
		case .keyboardF9:
			return 66
		case .keyboardF10:
			return 67
		case .keyboardF11:
			return 68
		case .keyboardF12:
			return 69
		case .keyboardPrintScreen:
			return 70
		case .keyboardScrollLock:
			return 71
		case .keyboardPause:
			return 72
		case .keyboardInsert:
			return 73
		case .keyboardHome:
			return 74
		case .keyboardPageUp:
			return 75
		case .keyboardDeleteForward:
			return 76
		case .keyboardEnd:
			return 77
		case .keyboardPageDown:
			return 78
		case .keyboardRightArrow:
			return 79
		case .keyboardLeftArrow:
			return 80
		case .keyboardDownArrow:
			return 81
		case .keyboardUpArrow:
			return 82
		case .keypadNumLock:
			return 83
		case .keypadSlash:
			return 84
		case .keypadAsterisk:
			return 85
		case .keypadHyphen:
			return 86
		case .keypadPlus:
			return 87
		case .keypadEnter:
			return 88
		case .keypad1:
			return 89
		case .keypad2:
			return 90
		case .keypad3:
			return 91
		case .keypad4:
			return 92
		case .keypad5:
			return 93
		case .keypad6:
			return 94
		case .keypad7:
			return 95
		case .keypad8:
			return 96
		case .keypad9:
			return 97
		case .keypad0:
			return 98
		case .keypadPeriod:
			return 99
		case .keyboardNonUSBackslash:
			return 100
		case .keyboardApplication:
			return 101
		case .keyboardPower:
			return 102
		case .keypadEqualSign:
			return 103
		case .keyboardF13:
			return 104
		case .keyboardF14:
			return 105
		case .keyboardF15:
			return 106
		case .keyboardF16:
			return 107
		case .keyboardF17:
			return 108
		case .keyboardF18:
			return 109
		case .keyboardF19:
			return 110
		case .keyboardF20:
			return 111
		case .keyboardF21:
			return 112
		case .keyboardF22:
			return 113
		case .keyboardF23:
			return 114
		case .keyboardF24:
			return 115
		case .keyboardExecute:
			return 116
		case .keyboardHelp:
			return 117
		case .keyboardMenu:
			return 118
		case .keyboardSelect:
			return 119
		case .keyboardStop:
			return 120
		case .keyboardAgain:
			return 121
		case .keyboardUndo:
			return 122
		case .keyboardCut:
			return 123
		case .keyboardCopy:
			return 124
		case .keyboardPaste:
			return 125
		case .keyboardFind:
			return 126
		case .keyboardMute:
			return 127
		case .keyboardVolumeUp:
			return 128
		case .keyboardVolumeDown:
			return 129
		case .keyboardLockingCapsLock:
			return 130
		case .keyboardLockingNumLock:
			return 131
		case .keyboardLockingScrollLock:
			return 132
		case .keypadComma:
			return 133
		case .keypadEqualSignAS400:
			return 134
		case .keyboardInternational1:
			return 135
		case .keyboardInternational2:
			return 136
		case .keyboardInternational3:
			return 137
		case .keyboardInternational4:
			return 138
		case .keyboardInternational5:
			return 139
		case .keyboardInternational6:
			return 140
		case .keyboardInternational7:
			return 141
		case .keyboardInternational8:
			return 142
		case .keyboardInternational9:
			return 143
		case .keyboardLANG1:
			return 144
		case .keyboardLANG2:
			return 145
		case .keyboardLANG3:
			return 146
		case .keyboardLANG4:
			return 147
		case .keyboardLANG5:
			return 148
		case .keyboardLANG6:
			return 149
		case .keyboardLANG7:
			return 150
		case .keyboardLANG8:
			return 151
		case .keyboardLANG9:
			return 152
		case .keyboardAlternateErase:
			return 153
		case .keyboardSysReqOrAttention:
			return 154
		case .keyboardCancel:
			return 155
		case .keyboardClear:
			return 156
		case .keyboardPrior:
			return 157
		case .keyboardReturn:
			return 158
		case .keyboardSeparator:
			return 159
		case .keyboardOut:
			return 160
		case .keyboardOper:
			return 161
		case .keyboardClearOrAgain:
			return 162
		case .keyboardCrSelOrProps:
			return 163
		case .keyboardExSel:
			return 164
		case .keyboardLeftControl:
			return 224
		case .keyboardLeftShift:
			return 225
		case .keyboardLeftAlt:
			return 226
		case .keyboardLeftGUI:
			return 227
		case .keyboardRightControl:
			return 228
		case .keyboardRightShift:
			return 229
		case .keyboardRightAlt:
			return 230
		case .keyboardRightGUI:
			return 231
		case .keyboard_Reserved:
			return 65535
		case .keyboardHangul:
			return 144
		case .keyboardHanja:
			return 145
		case .keyboardKanaSwitch:
			return 144
		case .keyboardAlphanumericSwitch:
			return 145
		case .keyboardKatakana:
			return 146
		case .keyboardHiragana:
			return 147
		case .keyboardZenkakuHankakuKanji:
			return 148
		default:
			return 0
		}
	}

	static func parsecKeyCodeTranslator(_ str: String) -> RemoteKeyCode?
	{
		switch str
		{
			case "A": return RemoteKeyCode(rawValue: 4)
			case "B": return RemoteKeyCode(rawValue: 5)
			case "C": return RemoteKeyCode(rawValue: 6)
			case "D": return RemoteKeyCode(rawValue: 7)
			case "E": return RemoteKeyCode(rawValue: 8)
			case "F": return RemoteKeyCode(rawValue: 9)
			case "G": return RemoteKeyCode(rawValue: 10)
			case "H": return RemoteKeyCode(rawValue: 11)
			case "I": return RemoteKeyCode(rawValue: 12)
			case "J": return RemoteKeyCode(rawValue: 13)
			case "K": return RemoteKeyCode(rawValue: 14)
			case "L": return RemoteKeyCode(rawValue: 15)
			case "M": return RemoteKeyCode(rawValue: 16)
			case "N": return RemoteKeyCode(rawValue: 17)
			case "O": return RemoteKeyCode(rawValue: 18)
			case "P": return RemoteKeyCode(rawValue: 19)
			case "Q": return RemoteKeyCode(rawValue: 20)
			case "R": return RemoteKeyCode(rawValue: 21)
			case "S": return RemoteKeyCode(rawValue: 22)
			case "T": return RemoteKeyCode(rawValue: 23)
			case "U": return RemoteKeyCode(rawValue: 24)
			case "V": return RemoteKeyCode(rawValue: 25)
			case "W": return RemoteKeyCode(rawValue: 26)
			case "X": return RemoteKeyCode(rawValue: 27)
			case "Y": return RemoteKeyCode(rawValue: 28)
			case "Z": return RemoteKeyCode(rawValue: 29)
            case "Ñ": return RemoteKeyCode(rawValue: 51)
			case "1": return RemoteKeyCode(rawValue: 30)
			case "2": return RemoteKeyCode(rawValue: 31)
			case "3": return RemoteKeyCode(rawValue: 32)
			case "4": return RemoteKeyCode(rawValue: 33)
			case "5": return RemoteKeyCode(rawValue: 34)
			case "6": return RemoteKeyCode(rawValue: 35)
			case "7": return RemoteKeyCode(rawValue: 36)
			case "8": return RemoteKeyCode(rawValue: 37)
			case "9": return RemoteKeyCode(rawValue: 38)
			case "0": return RemoteKeyCode(rawValue: 39)
			case "ENTER": return RemoteKeyCode(rawValue: 40)
			case "UIKeyInputEscape": return RemoteKeyCode(rawValue: 41) // ESCAPE with re-factored
			case "BACKSPACE": return RemoteKeyCode(rawValue: 42)
			case "TAB": return RemoteKeyCode(rawValue: 43)
			case "SPACE": return RemoteKeyCode(rawValue: 44)
			case "MINUS": return RemoteKeyCode(rawValue: 45)
			case "EQUALS": return RemoteKeyCode(rawValue: 46)
			case "LBRACKET": return RemoteKeyCode(rawValue: 47)
			case "RBRACKET": return RemoteKeyCode(rawValue: 48)
			case "BACKSLASH": return RemoteKeyCode(rawValue: 49)
			case "SEMICOLON": return RemoteKeyCode(rawValue: 51)
			case "APOSTROPHE": return RemoteKeyCode(rawValue: 52)
			case "BACKTICK": return RemoteKeyCode(rawValue: 53)
			case "COMMA": return RemoteKeyCode(rawValue: 54)
			case "PERIOD": return RemoteKeyCode(rawValue: 55)
			case "SLASH": return RemoteKeyCode(rawValue: 56)
			case "CAPSLOCK": return RemoteKeyCode(rawValue: 57)
			case "F1": return RemoteKeyCode(rawValue: 58)
			case "F2": return RemoteKeyCode(rawValue: 59)
			case "F3": return RemoteKeyCode(rawValue: 60)
			case "F4": return RemoteKeyCode(rawValue: 61)
			case "F5": return RemoteKeyCode(rawValue: 62)
			case "F6": return RemoteKeyCode(rawValue: 63)
			case "F7": return RemoteKeyCode(rawValue: 64)
			case "F8": return RemoteKeyCode(rawValue: 65)
			case "F9": return RemoteKeyCode(rawValue: 66)
			case "F10": return RemoteKeyCode(rawValue: 67)
			case "F11": return RemoteKeyCode(rawValue: 68)
			case "F12": return RemoteKeyCode(rawValue: 69)
			case "PRINTSCREEN": return RemoteKeyCode(rawValue: 70)
			case "SCROLLLOCK": return RemoteKeyCode(rawValue: 71)
			case "PAUSE": return RemoteKeyCode(rawValue: 72)
			case "INSERT": return RemoteKeyCode(rawValue: 73)
			case "HOME": return RemoteKeyCode(rawValue: 74)
			case "PAGEUP": return RemoteKeyCode(rawValue: 75)
			case "DELETE": return RemoteKeyCode(rawValue: 76)
			case "END": return RemoteKeyCode(rawValue: 77)
			case "PAGEDOWN": return RemoteKeyCode(rawValue: 78)
			case "RIGHT": return RemoteKeyCode(rawValue: 79)
			case "LEFT": return RemoteKeyCode(rawValue: 80)
			case "DOWN": return RemoteKeyCode(rawValue: 81)
			case "UP": return RemoteKeyCode(rawValue: 82)
			case "NUMLOCK": return RemoteKeyCode(rawValue: 83)
			case "KP_DIVIDE": return RemoteKeyCode(rawValue: 84)
			case "KP_MULTIPLY": return RemoteKeyCode(rawValue: 85)
			case "KP_MINUS": return RemoteKeyCode(rawValue: 86)
			case "KP_PLUS": return RemoteKeyCode(rawValue: 87)
			case "KP_ENTER": return RemoteKeyCode(rawValue: 88)
			case "KP_1": return RemoteKeyCode(rawValue: 89)
			case "KP_2": return RemoteKeyCode(rawValue: 90)
			case "KP_3": return RemoteKeyCode(rawValue: 91)
			case "KP_4": return RemoteKeyCode(rawValue: 92)
			case "KP_5": return RemoteKeyCode(rawValue: 93)
			case "KP_6": return RemoteKeyCode(rawValue: 94)
			case "KP_7": return RemoteKeyCode(rawValue: 95)
			case "KP_8": return RemoteKeyCode(rawValue: 96)
			case "KP_9": return RemoteKeyCode(rawValue: 97)
			case "KP_0": return RemoteKeyCode(rawValue: 98)
			case "KP_PERIOD": return RemoteKeyCode(rawValue: 99)
			case "APPLICATION": return RemoteKeyCode(rawValue: 101)
			case "F13": return RemoteKeyCode(rawValue: 104)
			case "F14": return RemoteKeyCode(rawValue: 105)
			case "F15": return RemoteKeyCode(rawValue: 106)
			case "F16": return RemoteKeyCode(rawValue: 107)
			case "F17": return RemoteKeyCode(rawValue: 108)
			case "F18": return RemoteKeyCode(rawValue: 109)
			case "F19": return RemoteKeyCode(rawValue: 110)
			case "MENU": return RemoteKeyCode(rawValue: 118)
			case "MUTE": return RemoteKeyCode(rawValue: 127)
			case "VOLUMEUP": return RemoteKeyCode(rawValue: 128)
			case "VOLUMEDOWN": return RemoteKeyCode(rawValue: 129)
			case "CONTROL": return RemoteKeyCode(rawValue: 224)
			case "SHIFT": return RemoteKeyCode(rawValue: 225)
			case "LALT": return RemoteKeyCode(rawValue: 226)
			case "LGUI": return RemoteKeyCode(rawValue: 227)
			case "RCTRL": return RemoteKeyCode(rawValue: 228)
			case "RSHIFT": return RemoteKeyCode(rawValue: 229)
			case "RALT": return RemoteKeyCode(rawValue: 230)
			case "RGUI": return RemoteKeyCode(rawValue: 231)
			case "AUDIONEXT": return RemoteKeyCode(rawValue: 258)
			case "AUDIOPREV": return RemoteKeyCode(rawValue: 259)
			case "AUDIOSTOP": return RemoteKeyCode(rawValue: 260)
			case "AUDIOPLAY": return RemoteKeyCode(rawValue: 261)
			case "AUDIOMUTE": return RemoteKeyCode(rawValue: 262)
			case "MEDIASELECT": return RemoteKeyCode(rawValue: 263)

			default: return nil
		}
	}
	
	static func getRemoteKeyCode(for key: String) -> (remoteKeyCode: Int, keyMod: Bool) {
		var keyMod = false
		var parsecKeycode: Int = 0
		
		switch key {
			// Non-shifted characters
		case "-", "－":  // U+FF0D fullwidth hyphen-minus
			parsecKeycode = 45
		case "=", "＝":  // U+FF1D fullwidth equals sign
			parsecKeycode = 46
		case "[", "［":  // U+FF3B fullwidth left square bracket
			parsecKeycode = 47
		case "]", "］":  // U+FF3D fullwidth right square bracket
			parsecKeycode = 48
		case "\\", "＼":  // U+FF3C fullwidth reverse solidus
			parsecKeycode = 49
		case ";", "；":  // U+FF1B fullwidth semicolon
			parsecKeycode = 51
		case "'":
			parsecKeycode = 52
		case "`":
			parsecKeycode = 53
		case ",", "，":  // U+FF0C fullwidth comma
			parsecKeycode = 54
		case ".", "．":  // U+FF0E fullwidth full stop
			parsecKeycode = 55
		case "/", "／":  // U+FF0F fullwidth solidus
			parsecKeycode = 56
			
			// Shifted characters
		case "_", "＿":  // U+FF3F fullwidth low line
			parsecKeycode = 45
			keyMod = true
		case "+", "＋":  // U+FF0B fullwidth plus sign
			parsecKeycode = 46
			keyMod = true
		case "{", "｛":  // U+FF5B fullwidth left curly bracket
			parsecKeycode = 47
			keyMod = true
		case "}", "｝":  // U+FF5D fullwidth right curly bracket
			parsecKeycode = 48
			keyMod = true
		case "|", "｜":  // U+FF5C fullwidth vertical line
			parsecKeycode = 49
			keyMod = true
		case ":", "：":  // U+FF1A fullwidth colon
			parsecKeycode = 51
			keyMod = true
		case "\"":
			parsecKeycode = 52
			keyMod = true
		case "~", "～":  // U+FF5E fullwidth tilde
			parsecKeycode = 53
			keyMod = true
		case "<", "＜":  // U+FF1C fullwidth less-than sign
			parsecKeycode = 54
			keyMod = true
		case ">", "＞":  // U+FF1E fullwidth greater-than sign
			parsecKeycode = 55
			keyMod = true
		case "?", "？":  // U+FF1F fullwidth question mark
			parsecKeycode = 56
			keyMod = true
		case "!", "！":  // U+FF01 fullwidth exclamation mark
			parsecKeycode = 30
			keyMod = true
		case "@", "＠":  // U+FF20 fullwidth commercial at
			parsecKeycode = 31
			keyMod = true
		case "#", "＃":  // U+FF03 fullwidth number sign
			parsecKeycode = 32
			keyMod = true
		case "$", "＄":  // U+FF04 fullwidth dollar sign
			parsecKeycode = 33
			keyMod = true
		case "%", "％":  // U+FF05 fullwidth percent sign
			parsecKeycode = 34
			keyMod = true
		case "^", "＾":  // U+FF3E fullwidth circumflex accent
			parsecKeycode = 35
			keyMod = true
		case "&", "＆":  // U+FF06 fullwidth ampersand
			parsecKeycode = 36
			keyMod = true
		case "*", "＊":  // U+FF0A fullwidth asterisk
			parsecKeycode = 37
			keyMod = true
		case "(", "（":  // U+FF08 fullwidth left parenthesis
			parsecKeycode = 38
			keyMod = true
		case ")", "）":  // U+FF09 fullwidth right parenthesis
			parsecKeycode = 39
			keyMod = true
			
		default:
			parsecKeycode = -1 // Unknown key
		}
		
		return (parsecKeycode, keyMod)
	}
	
}
