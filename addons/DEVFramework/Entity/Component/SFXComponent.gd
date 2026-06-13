class_name SFXComponent extends Node

@export var audios: Dictionary[String, AudioStream]
@export var tweens: Dictionary[String, TweenAnimation]
@export var audio_player: Node

signal played(key: String)

func play(key: String):
	played.emit(key)
	if audios.has(key):
		audio_player.stream = audios[key]
		audio_player.play()
	if tweens.has(key):
		tweens[key].play()
