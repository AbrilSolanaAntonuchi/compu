extends Control
## Celular-PINCEL. Lee su propia orientación (giroscopio) y se la manda por WiFi al celular de
## las gafas. Se apunta con la parte de ATRÁS del celular, como una linterna.
##
## Se usa solo apuntando, como el mouse: no hay que tocar nada para pintar.
##  - Un único toque al inicio calibra (lo que estás apuntando = el centro de la pintura).
##  - Opcional, si con el tiempo la puntería se va corriendo: apoyar dos dedos recalibra.

const PUERTO := 47474           # puerto donde escuchan las gafas
const PUERTO_RESPUESTA := 47475 # puerto donde este celular recibe el aviso "te escucho"
const MAGIC := "VRP1"
const ENVIOS_POR_SEG := 40.0

# Mismos valores que habitacion.gd (si en el pincel el horizonte sale al revés, cambiá el signo)
const GRAVITY_CORRECTION := 0.02
const GRAVITY_SIGN := -1.0
const FORCE_COMPASS := false

var udp := PacketPeerUDP.new()
var destinos: Array[String] = []
var puerto_ok := false
var calib := 0
var toques := {}
var envio_acum := 0.0
var ultima_respuesta_ms := -100000

# Orientación del celular
var orient := Basis()
var gyro_activo := false
var gyro_espera := 0.0
var brujula_lista := false
var g_f := Vector3.ZERO
var m_f := Vector3.ZERO

var fondo: ColorRect
var texto: Label


func _ready() -> void:
	DisplayServer.screen_set_keep_on(true)
	_crear_interfaz()
	puerto_ok = udp.bind(PUERTO_RESPUESTA) == OK
	udp.set_broadcast_enabled(true)
	destinos = _calcular_destinos()


func _crear_interfaz() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	fondo = ColorRect.new()
	fondo.set_anchors_preset(Control.PRESET_FULL_RECT)
	fondo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(fondo)
	texto = Label.new()
	texto.set_anchors_preset(Control.PRESET_FULL_RECT)
	texto.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	texto.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	texto.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	texto.add_theme_font_size_override("font_size", 38)
	texto.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(texto)


## Direcciones a las que se emite: broadcast general y broadcast de cada red local (x.y.z.255)
func _calcular_destinos() -> Array[String]:
	var res: Array[String] = ["255.255.255.255"]
	for ip in IP.get_local_addresses():
		if ip.count(".") != 3:
			continue
		if ip.begins_with("192.168.") or ip.begins_with("10.") or ip.begins_with("172."):
			var p := ip.split(".")
			var b := "%s.%s.%s.255" % [p[0], p[1], p[2]]
			if not res.has(b):
				res.append(b)
	return res


# ---------------------------------------------------------------- Loop

func _process(delta: float) -> void:
	_actualizar_orientacion(delta)
	_leer_respuestas()

	envio_acum += delta
	if envio_acum >= 1.0 / ENVIOS_POR_SEG:
		envio_acum = 0.0
		_enviar()
	_actualizar_pantalla()


func _enviar() -> void:
	var dir := -orient.z    # hacia donde mira la parte trasera del celular
	var bytes := var_to_bytes([MAGIC, dir.x, dir.y, dir.z, calib, not toques.is_empty()])
	for d in destinos:
		udp.set_dest_address(d, PUERTO)
		udp.put_packet(bytes)


func _leer_respuestas() -> void:
	while udp.get_available_packet_count() > 0:
		var bytes := udp.get_packet()
		if bytes.get_string_from_utf8() == MAGIC + "OK":
			ultima_respuesta_ms = Time.get_ticks_msec()


func _actualizar_pantalla() -> void:
	var conectado := Time.get_ticks_msec() - ultima_respuesta_ms < 1500
	if not conectado:
		fondo.color = Color(0.35, 0.10, 0.10)
		texto.text = "BUSCANDO LAS GAFAS...\n\nAbrí la app en el otro celular y elegí GAFAS VR.\nLos dos tienen que estar en la misma red WiFi."
		if not puerto_ok:
			texto.text += "\n\n(No se pudo abrir el puerto de red)"
	elif calib == 0:
		fondo.color = Color(0.10, 0.25, 0.40)
		texto.text = "CONECTADO\n\nApuntá la parte de atrás del celular hacia la pintura\ny tocá la pantalla para calibrar."
	else:
		fondo.color = Color(0.08, 0.30, 0.15)
		texto.text = "PINCEL LISTO\n\nApuntá hacia la pintura para pintar.\n(Si se corre la puntería: dos dedos apuntando a la pintura = recalibrar)"


func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			toques[event.index] = true
			if calib == 0 or toques.size() >= 2:
				calib += 1
		else:
			toques.erase(event.index)


# ---------------------------------------------------------------- Orientación (igual que habitacion.gd)

func _actualizar_orientacion(delta: float) -> void:
	if Input.get_gyroscope() != Vector3.ZERO:
		gyro_activo = true
	gyro_espera += delta
	if FORCE_COMPASS or (not gyro_activo and gyro_espera > 1.0):
		_brujula()
	else:
		_giroscopio(delta)


func _brujula() -> void:
	var g := Input.get_gravity()
	if g.length() < 1.0:
		g = Input.get_accelerometer()
	var m := Input.get_magnetometer()
	if g.length() < 1.0 or m.length() < 0.01:
		return
	g *= GRAVITY_SIGN
	g_f = g if g_f == Vector3.ZERO else g_f.lerp(g, 0.2)
	m_f = m if m_f == Vector3.ZERO else m_f.lerp(m, 0.1)
	var up := g_f.normalized()
	var east := m_f.cross(up)
	if east.length() < 0.01:
		return
	east = east.normalized()
	var north := up.cross(east)
	var objetivo := Basis(east, up, -north).transposed()
	if not brujula_lista:
		orient = objetivo
		brujula_lista = true
	else:
		orient = orient.slerp(objetivo, 0.2)


func _giroscopio(delta: float) -> void:
	var w := Input.get_gyroscope()
	if w.length() > 0.0001:
		orient = (orient * Basis(w.normalized(), w.length() * delta)).orthonormalized()

	if GRAVITY_CORRECTION > 0.0:
		var g := Input.get_gravity()
		if g.length() < 1.0:
			g = Input.get_accelerometer()
		if g.length() > 1.0:
			var arriba_medido := (g * GRAVITY_SIGN).normalized()
			var arriba_esperado := orient.inverse() * Vector3.UP
			var eje := arriba_medido.cross(arriba_esperado)
			if eje.length() > 0.0001:
				var angulo := arriba_medido.angle_to(arriba_esperado) * GRAVITY_CORRECTION
				orient = (orient * Basis(eje.normalized(), angulo)).orthonormalized()
