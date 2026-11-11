extends Node
## Lets the person hear the field with their hands. A sine tone follows each
## tracked hand's index fingertip: higher where the field there is stronger,
## and silent outside it. Each hand's tone leans toward its own side. Works
## with whatever hands the volume has, which on visionOS means while it is
## immersive.

## The tone at the weakest and strongest values, in hertz. Pitch rises
## evenly in octaves between them.
const PITCH := Vector2(220.0, 880.0)
const LOUDNESS := 0.2
## How far each hand's tone leans toward its side, from 0 to 1.
const PAN := 0.6
## How quickly pitch and loudness follow the fingertip, per second: fast
## enough to feel immediate, slow enough not to click.
const GLIDE := 30.0
## Seconds of sound kept ready ahead.
const BUFFER := 0.1

## Samples the field for us, as it does for haptics.
var touch: Node
var volume: SpatialVolume3D

## Per hand tracker: its player and where its tone is.
var _voices := {}


func _process(_delta: float) -> void:
	if volume == null:
		return
	var hands := volume.get_hands()
	for hand in hands:
		if not _voices.has(hand):
			_voices[hand] = _add_voice(hand)
	for hand: XRHandTracker in _voices:
		var voice: Dictionary = _voices[hand]
		var value := 0.0
		if hand in hands:
			var tip := volume.get_hand_joint(hand, XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP).origin
			value = touch.value_of(touch.cell_at(tip))
		voice.target_loudness = LOUDNESS if value > 0.0 else 0.0
		if value > 0.0:
			voice.target_pitch = PITCH.x * pow(PITCH.y / PITCH.x, value)
		_fill(voice)


func _add_voice(hand: XRHandTracker) -> Dictionary:
	var stream := AudioStreamGenerator.new()
	stream.mix_rate = AudioServer.get_mix_rate()
	stream.buffer_length = BUFFER
	var player := AudioStreamPlayer.new()
	player.stream = stream
	add_child(player)
	player.play()
	var side := -1.0 if hand.hand == XRPositionalTracker.TRACKER_HAND_LEFT else 1.0
	return {
		playback = player.get_stream_playback(),
		rate = stream.mix_rate,
		# Equal-power gains for the left and right channels.
		gains = Vector2(cos((1.0 + side * PAN) * PI / 4.0), sin((1.0 + side * PAN) * PI / 4.0)),
		phase = 0.0,
		pitch = PITCH.x,
		target_pitch = PITCH.x,
		loudness = 0.0,
		target_loudness = 0.0,
	}


## Writes as much of the voice's tone as its player has room for, easing
## toward the target pitch and loudness sample by sample.
func _fill(voice: Dictionary) -> void:
	var playback: AudioStreamGeneratorPlayback = voice.playback
	var frames := playback.get_frames_available()
	if frames == 0:
		return
	var rate: float = voice.rate
	var follow := 1.0 - exp(-GLIDE / rate)
	var phase: float = voice.phase
	var pitch: float = voice.pitch
	var loudness: float = voice.loudness
	var target_pitch: float = voice.target_pitch
	var target_loudness: float = voice.target_loudness
	var gains: Vector2 = voice.gains
	var buffer := PackedVector2Array()
	buffer.resize(frames)
	for i in frames:
		pitch += (target_pitch - pitch) * follow
		loudness += (target_loudness - loudness) * follow
		phase = fmod(phase + pitch / rate, 1.0)
		buffer[i] = gains * (sin(phase * TAU) * loudness)
	playback.push_buffer(buffer)
	voice.phase = phase
	voice.pitch = pitch
	voice.loudness = loudness
