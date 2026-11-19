extends Control
## Pantalla de inicio. Se instala el MISMO APK en los dos celulares y cada uno elige su rol.

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var fondo := ColorRect.new()
	fondo.color = Color(0.04, 0.08, 0.22)
	fondo.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(fondo)

	var centro := CenterContainer.new()
	centro.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(centro)

	var caja := VBoxContainer.new()
	caja.add_theme_constant_override("separation", 30)
	centro.add_child(caja)

	var titulo := Label.new()
	titulo.text = "¿Qué es este celular?"
	titulo.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	titulo.add_theme_font_size_override("font_size", 44)
	caja.add_child(titulo)

	var fila := HBoxContainer.new()
	fila.add_theme_constant_override("separation", 40)
	caja.add_child(fila)

	fila.add_child(_boton("GAFAS VR\n(va dentro del visor)", "res://habitacion.tscn"))
	fila.add_child(_boton("PINCEL\n(lo sostenés en la mano)", "res://pincel.tscn"))


func _boton(texto: String, escena: String) -> Button:
	var b := Button.new()
	b.text = texto
	b.custom_minimum_size = Vector2(430, 260)
	b.add_theme_font_size_override("font_size", 34)
	b.pressed.connect(func(): get_tree().change_scene_to_file(escena))
	return b
