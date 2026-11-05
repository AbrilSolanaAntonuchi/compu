extends Node3D
## VR estilo Cardboard (Android) para tu habitación.
## La habitación, la luz y el entorno están en la escena; este script solo
## crea la vista estéreo (un ojo por mitad de pantalla) y controla la cabeza.
##
## - Celular: el giroscopio gira la cabeza; mantener tocada la pantalla camina hacia donde miras.
## - PC (para probar): mouse = mirar, WASD = caminar, Esc = soltar el mouse.

const IPD := 0.064              # distancia entre ojos (64 mm)
const WALK_SPEED := 2.0         # m/s (caminar tocando la pantalla)

# Detección de pasos con el acelerómetro
const USE_STEP_DETECTION := true
const USE_TOUCH_WALK := true    # mantener tocada la pantalla también camina
const STEP_LENGTH := 0.6        # metros que avanzas en el juego por cada paso real
const STEP_SPEED := 2.5         # m/s con que se "reparte" ese avance (suaviza)
const STEP_THRESHOLD := 0.65    # sensibilidad (m/s²). Más bajo = detecta más fácil
const STEP_MIN_INTERVAL := 0.3  # segundos mínimos entre pasos
const ROOM_HALF := 1.95         # mitad del interior (paredes en ±2, grosor 0.1)
const PLAYER_RADIUS := 0.3      # distancia mínima a las paredes
const EYE_FOV := 90.0           # FOV vertical de cada ojo

const GRAVITY_CORRECTION := 0.02  # corrección de deriva con gravedad (0 = off)
const GRAVITY_SIGN := -1.0       # pon -1.0 si el horizonte sale inclinado/al revés

# Muestra un panel con datos de sensores y pasos (ponelo en false cuando termines de probar)
const DEBUG_HUD := true

# true = usar siempre la brújula (útil si el celular no tiene giroscopio o gira mal)
const FORCE_COMPASS := false

const LENS_K1 := 0.15           # distorsión de barril para las lentes
const LENS_K2 := 0.05           # (0 y 0 = sin distorsión)

@onready var head: Node3D = $Cabeza
@onready var env: Environment = $WorldEnvironment.environment

var cam_left: Camera3D
var cam_right: Camera3D
var is_mobile := false
var touching := false
var yaw := 0.0
var pitch := 0.0
var gyro_active := false
var gyro_wait := 0.0
var compass_ready := false
var g_f := Vector3.ZERO
var m_f := Vector3.ZERO
var accel_base := 9.8
var accel_smooth := 0.0
var step_armed := true
var step_cooldown := 0.0
var pending_distance := 0.0
var step_count := 0
var orient_mode := "?"
var hud: Label


func _ready() -> void:
	is_mobile = OS.has_feature("mobile")
	_build_stereo_ui()
	if DEBUG_HUD:
		_build_hud()
	if not is_mobile:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


# ---------------------------------------------------------------- Vista estereo

func _build_stereo_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)

	var hbox := HBoxContainer.new()
	hbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	hbox.add_theme_constant_override("separation", 0)
	layer.add_child(hbox)

	var mat := ShaderMaterial.new()
	mat.shader = _make_lens_shader()
	mat.set_shader_parameter("k1", LENS_K1)
	mat.set_shader_parameter("k2", LENS_K2)

	cam_left = _make_eye(hbox, mat)
	cam_right = _make_eye(hbox, mat)


func _make_eye(parent: Control, mat: ShaderMaterial) -> Camera3D:
	var container := SubViewportContainer.new()
	container.stretch = true
	container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	container.material = mat
	parent.add_child(container)

	var vp := SubViewport.new()
	vp.world_3d = get_viewport().world_3d   # comparte el mismo mundo 3D
	vp.msaa_3d = Viewport.MSAA_DISABLED
	container.add_child(vp)

	var cam := Camera3D.new()
	cam.fov = EYE_FOV
	cam.environment = env
	cam.current = true
	vp.add_child(cam)
	return cam


func _make_lens_shader() -> Shader:
	var s := Shader.new()
	s.code = """
shader_type canvas_item;
uniform float k1 = 0.15;
uniform float k2 = 0.05;
void fragment() {
	vec2 c = UV * 2.0 - 1.0;
	float r2 = dot(c, c);
	vec2 d = c * (1.0 + k1 * r2 + k2 * r2 * r2);
	vec2 uv = d * 0.5 + 0.5;
	if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
		COLOR = vec4(0.0, 0.0, 0.0, 1.0);
	} else {
		COLOR = texture(TEXTURE, uv);
	}
}
"""
	return s


# ---------------------------------------------------------------- Loop

func _process(delta: float) -> void:
	if is_mobile:
		_update_orientation(delta)
		if USE_STEP_DETECTION:
			_update_steps(delta)
		if USE_TOUCH_WALK and touching:
			_walk(-head.global_transform.basis.z, WALK_SPEED * delta)
	else:
		_update_keyboard(delta)

	# Consumir el avance pendiente de los pasos (móvil) o de la barra espaciadora (PC)
	if pending_distance > 0.0:
		var dist := minf(pending_distance, STEP_SPEED * delta)
		pending_distance -= dist
		_walk(-head.global_transform.basis.z, dist)

	if DEBUG_HUD:
		_update_hud()

	var half := IPD / 2.0
	cam_left.global_transform = head.global_transform * Transform3D(Basis(), Vector3(-half, 0, 0))
	cam_right.global_transform = head.global_transform * Transform3D(Basis(), Vector3(half, 0, 0))


func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		touching = event.pressed
	elif not is_mobile and event is InputEventMouseMotion \
			and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		yaw -= event.relative.x * 0.003
		pitch = clampf(pitch - event.relative.y * 0.003, -1.5, 1.5)
		head.basis = Basis.from_euler(Vector3(pitch, yaw, 0))
	elif not is_mobile and event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_SPACE:
		pending_distance += STEP_LENGTH   # simula un paso en la PC
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton and event.pressed and not is_mobile:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


# ---------------------------------------------------------------- Orientacion (celular)

func _update_orientation(delta: float) -> void:
	# Si el giroscopio nunca da datos (celular sin giroscopio), usar la brújula
	if Input.get_gyroscope() != Vector3.ZERO:
		gyro_active = true
	gyro_wait += delta
	if FORCE_COMPASS or (not gyro_active and gyro_wait > 1.0):
		orient_mode = "BRUJULA"
		_update_compass()
	else:
		orient_mode = "GIROSCOPIO" if gyro_active else "esperando..."
		_update_gyro(delta)


func _update_compass() -> void:
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
	var target := Basis(east, up, -north).transposed()
	if not compass_ready:
		head.basis = target
		compass_ready = true
	else:
		head.basis = head.basis.slerp(target, 0.2)


func _update_gyro(delta: float) -> void:
	var w := Input.get_gyroscope()
	if w.length() > 0.0001:
		head.basis = (head.basis * Basis(w.normalized(), w.length() * delta)).orthonormalized()

	if GRAVITY_CORRECTION > 0.0:
		var g := Input.get_gravity()
		if g.length() < 1.0:
			g = Input.get_accelerometer()
		if g.length() > 1.0:
			var measured_up := (g * GRAVITY_SIGN).normalized()
			var expected_up := head.basis.inverse() * Vector3.UP
			var axis := measured_up.cross(expected_up)
			if axis.length() > 0.0001:
				var angle := measured_up.angle_to(expected_up) * GRAVITY_CORRECTION
				head.basis = (head.basis * Basis(axis.normalized(), angle)).orthonormalized()


# ---------------------------------------------------------------- Movimiento

func _update_keyboard(delta: float) -> void:
	var dir := Vector3.ZERO
	var b := head.global_transform.basis
	if Input.is_key_pressed(KEY_W): dir -= b.z
	if Input.is_key_pressed(KEY_S): dir += b.z
	if Input.is_key_pressed(KEY_A): dir -= b.x
	if Input.is_key_pressed(KEY_D): dir += b.x
	_walk(dir, WALK_SPEED * delta)


func _walk(dir: Vector3, dist: float) -> void:
	var flat := Vector3(dir.x, 0.0, dir.z)
	if flat.length() < 0.05:
		return
	var pos := head.position + flat.normalized() * dist
	var limit := ROOM_HALF - PLAYER_RADIUS
	pos.x = clampf(pos.x, -limit, limit)
	pos.z = clampf(pos.z, -limit, limit)
	head.position = pos


# ---------------------------------------------------------------- Pasos reales

func _update_steps(delta: float) -> void:
	var a := Input.get_accelerometer().length()
	if a < 1.0:
		return
	# Magnitud de la aceleración menos su promedio lento = solo los golpes de cada paso
	accel_base = lerpf(accel_base, a, 1.0 - exp(-delta / 0.5))
	accel_smooth = lerpf(accel_smooth, a - accel_base, 1.0 - exp(-delta / 0.05))
	step_cooldown -= delta
	if step_armed and accel_smooth > STEP_THRESHOLD and step_cooldown <= 0.0:
		pending_distance = minf(pending_distance + STEP_LENGTH, 2.0)
		step_count += 1
		step_cooldown = STEP_MIN_INTERVAL
		step_armed = false
	elif accel_smooth < STEP_THRESHOLD * 0.4:
		step_armed = true


# ---------------------------------------------------------------- Panel de depuración

func _build_hud() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 10
	add_child(layer)
	hud = Label.new()
	hud.position = Vector2(20, 10)
	hud.add_theme_font_size_override("font_size", 22)
	hud.add_theme_color_override("font_color", Color.WHITE)
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0, 0, 0, 0.75)
	bg.set_content_margin_all(8)
	hud.add_theme_stylebox_override("normal", bg)
	layer.add_child(hud)


func _v(v: Vector3) -> String:
	return "(%.2f, %.2f, %.2f)" % [v.x, v.y, v.z]


func _update_hud() -> void:
	var a := Input.get_accelerometer()
	hud.text = "FPS: %d\n" % Engine.get_frames_per_second() \
		+ "Orientacion: %s\n" % orient_mode \
		+ "Gyro activo: %s  %s\n" % [str(gyro_active), _v(Input.get_gyroscope())] \
		+ "Gravedad: %s\n" % _v(Input.get_gravity()) \
		+ "Acelerom: %s |a|=%.2f\n" % [_v(a), a.length()] \
		+ "Magnet: %s\n" % _v(Input.get_magnetometer()) \
		+ "Paso: base=%.2f suave=%.2f umbral=%.2f\n" % [accel_base, accel_smooth, STEP_THRESHOLD] \
		+ "PASOS: %d   pendiente: %.2f m\n" % [step_count, pending_distance] \
		+ "Pos: %s" % _v(head.position)
