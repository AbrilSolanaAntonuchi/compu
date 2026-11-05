extends Node3D
## Pintura con efecto de pixelado por AUTÓMATA CELULAR, colgada en una pared del cuarto 3D.
##
## El efecto es el mismo que en la versión 2D, pero en vez del mouse se "apunta" con la mirada:
## desde la cabeza sale un rayo hacia adelante, y donde ese rayo toca la pintura, las celdas
## se van pixelando.
##
## Estados de cada celda: VIRGEN -> ACTIVA (transición gradual) -> PIXELADA (final, permanente).
## Una celda VIRGEN solo puede activarse si la mirada cae dentro del radio del pincel, con
## probabilidad  p = prob_siembra + influencia_vecinas * n  (n = vecinas ya afectadas, de 8).
## No hay contagio fuera del radio y ninguna celda vuelve a VIRGEN.
##
## La pintura queda en el plano local XY de este nodo, mirando hacia +Z.
## Para moverla a otra pared basta con cambiar la posición y la rotación del nodo.

@export var ruta_imagen: String = "res://pintura.png"   # imagen de la pintura (si no existe, usa una de prueba)
@export var alto_m: float = 1.4                          # alto de la pintura en metros (el ancho sale de la proporción)
@export var cabeza_path: NodePath = ^"../Cabeza"         # nodo desde donde se mira
@export var radio_pincel_m: float = 0.15                 # radio del área afectada, en metros sobre la pared
@export var tamano_pixel: int = 12                       # tamaño de cada celda, en píxeles de la imagen
@export_range(0.0, 1.0) var prob_siembra: float = 0.08   # prob. base por paso de activar una celda
@export_range(0.0, 0.5) var influencia_vecinas: float = 0.1   # prob. extra por cada vecina ya afectada
@export var pasos_transicion: int = 4                    # pasos que dura una celda en estado ACTIVA
@export var segundos_por_paso: float = 0.03              # velocidad del autómata
@export var mostrar_puntero: bool = true                 # círculo que muestra dónde actúa el pincel
@export var suavizado: float = 10.0                      # estabiliza el puntero (0 = sin suavizar)

const VIRGEN := 0
const ACTIVA := 1
const PIXELADA := 2

const SHADER_CODE := """
shader_type spatial;
render_mode unshaded;
uniform sampler2D original : source_color, filter_linear;
uniform sampler2D celdas : source_color, filter_nearest;
void fragment() {
	vec3 base = texture(original, UV).rgb;
	vec4 c = texture(celdas, UV);
	ALBEDO = mix(base, c.rgb, c.a);
}
"""

# Puntero: anillo claro con borde oscuro (se ve sobre cualquier color) y un punto en el centro
const PUNTERO_SHADER_CODE := """
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled;
float banda(float r, float a, float b) {
	return smoothstep(a - 0.02, a, r) * (1.0 - smoothstep(b, b + 0.02, r));
}
void fragment() {
	float r = length(UV * 2.0 - 1.0);
	float oscuro = max(banda(r, 0.80, 0.97), 1.0 - smoothstep(0.07, 0.09, r));
	float claro = max(banda(r, 0.84, 0.93), 1.0 - smoothstep(0.04, 0.05, r));
	ALBEDO = mix(vec3(0.05), vec3(1.0), claro);
	ALPHA = oscuro;
}
"""

var cabeza: Node3D
var textura_original: Texture2D
var imagen_original: Image
var ancho_m := 1.0
var cols := 0
var filas := 0
var estado := PackedByteArray()
var edad := PackedByteArray()
var colores := PackedByteArray()      # RGB promedio de cada celda (3 bytes por celda)
var imagen_overlay: Image
var textura_overlay: ImageTexture

var acumulador := 0.0
var hay_cambios := true
var puntero_img := Vector2.ZERO       # punto apuntado, en píxeles de la imagen
var ultimo_apuntado_ms := -10000
var objetivo := Vector2.ZERO          # punto tocado por el rayo, en metros sobre la pintura (sin suavizar)
var punto := Vector2.ZERO             # ese punto ya suavizado
var estaba_apuntando := false
var puntero: MeshInstance3D
var rng := RandomNumberGenerator.new()


func _ready() -> void:
	rng.randomize()
	cabeza = get_node_or_null(cabeza_path) as Node3D
	if cabeza == null:
		push_warning("PinturaCA: no se encontró el nodo de la cabeza en '%s'." % str(cabeza_path))

	textura_original = _cargar_textura()
	imagen_original = textura_original.get_image()
	if imagen_original.is_compressed():
		imagen_original.decompress()

	var tam := imagen_original.get_size()
	ancho_m = alto_m * float(tam.x) / float(tam.y)

	_crear_grilla()
	_crear_malla()


# ---------------------------------------------------------------- Preparación

func _cargar_textura() -> Texture2D:
	# Prueba primero la ruta indicada y después algunos lugares habituales
	var candidatas := [
		ruta_imagen,
		"res://coasas/1.jpg!PinterestSmall.png",
		"res://1.jpg!PinterestSmall.png",
	]
	for ruta in candidatas:
		if ruta != "" and ResourceLoader.exists(ruta):
			var t = load(ruta)
			if t is Texture2D:
				print("PinturaCA: usando la imagen ", ruta)
				return t
	push_warning("PinturaCA: no se encontró la imagen '%s'. Se usa una imagen de prueba." % ruta_imagen)
	return ImageTexture.create_from_image(_imagen_de_prueba())


func _imagen_de_prueba() -> Image:
	var w := 240
	var h := 320
	var img := Image.create(w, h, false, Image.FORMAT_RGB8)
	for y in h:
		for x in w:
			var u := float(x) / w
			var v := float(y) / h
			var d := Vector2(u - 0.5, v - 0.5).length()
			var tono := fposmod(u * 0.6 + sin(d * 18.0) * 0.08 + v * 0.3, 1.0)
			var brillo := clampf(0.55 + 0.4 * cos(d * 14.0), 0.0, 1.0)
			img.set_pixel(x, y, Color.from_hsv(tono, 0.75, brillo))
	return img


func _crear_grilla() -> void:
	var tam := imagen_original.get_size()
	cols = maxi(1, ceili(float(tam.x) / tamano_pixel))
	filas = maxi(1, ceili(float(tam.y) / tamano_pixel))
	var n := cols * filas

	estado = PackedByteArray()
	estado.resize(n)
	edad = PackedByteArray()
	edad.resize(n)
	colores = PackedByteArray()
	colores.resize(n * 3)

	# Color de cada celda = promedio de una muestra de 4x4 puntos dentro de la celda
	var m := 4
	for cy in filas:
		for cx in cols:
			var x0 := float(cx) * tam.x / cols
			var x1 := float(cx + 1) * tam.x / cols
			var y0 := float(cy) * tam.y / filas
			var y1 := float(cy + 1) * tam.y / filas
			var r := 0.0
			var g := 0.0
			var b := 0.0
			for sy in m:
				for sx in m:
					var px := clampi(int(lerpf(x0, x1, (sx + 0.5) / m)), 0, tam.x - 1)
					var py := clampi(int(lerpf(y0, y1, (sy + 0.5) / m)), 0, tam.y - 1)
					var c := imagen_original.get_pixel(px, py)
					r += c.r
					g += c.g
					b += c.b
			var i := (cy * cols + cx) * 3
			colores[i] = int(r / (m * m) * 255.0)
			colores[i + 1] = int(g / (m * m) * 255.0)
			colores[i + 2] = int(b / (m * m) * 255.0)

	imagen_overlay = Image.create(cols, filas, false, Image.FORMAT_RGBA8)
	textura_overlay = ImageTexture.create_from_image(imagen_overlay)
	hay_cambios = true


func _crear_malla() -> void:
	# La pintura: un cuadro con un shader que mezcla la imagen original con las celdas pixeladas
	var quad := QuadMesh.new()
	quad.size = Vector2(ancho_m, alto_m)

	var shader := Shader.new()
	shader.code = SHADER_CODE
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("original", textura_original)
	mat.set_shader_parameter("celdas", textura_overlay)

	var cuadro := MeshInstance3D.new()
	cuadro.mesh = quad
	cuadro.material_override = mat
	add_child(cuadro)

	# Un marco oscuro detrás
	var marco_mesh := QuadMesh.new()
	marco_mesh.size = Vector2(ancho_m + 0.1, alto_m + 0.1)
	var marco_mat := StandardMaterial3D.new()
	marco_mat.albedo_color = Color(0.12, 0.09, 0.07)
	marco_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var marco := MeshInstance3D.new()
	marco.mesh = marco_mesh
	marco.material_override = marco_mat
	marco.position = Vector3(0.0, 0.0, -0.004)
	add_child(marco)

	# Puntero: círculo del tamaño exacto del pincel, apoyado sobre la pintura
	var puntero_mesh := QuadMesh.new()
	puntero_mesh.size = Vector2(radio_pincel_m * 2.0, radio_pincel_m * 2.0)
	var puntero_shader := Shader.new()
	puntero_shader.code = PUNTERO_SHADER_CODE
	var puntero_mat := ShaderMaterial.new()
	puntero_mat.shader = puntero_shader
	puntero = MeshInstance3D.new()
	puntero.mesh = puntero_mesh
	puntero.material_override = puntero_mat
	puntero.visible = false
	add_child(puntero)


# ---------------------------------------------------------------- Loop

func _process(delta: float) -> void:
	if cabeza != null:
		apuntar_rayo(cabeza.global_position, -cabeza.global_transform.basis.z)

	# Suavizar el punto apuntado (la brújula tiembla un poco) y mover el puntero
	var apuntando := Time.get_ticks_msec() - ultimo_apuntado_ms < 120
	if apuntando:
		if not estaba_apuntando or suavizado <= 0.0:
			punto = objetivo
		else:
			punto = punto.lerp(objetivo, 1.0 - exp(-suavizado * delta))
		var uv := Vector2(punto.x / ancho_m + 0.5, 0.5 - punto.y / alto_m)
		puntero_img = uv * Vector2(imagen_original.get_size())
		puntero.position = Vector3(punto.x, punto.y, 0.006)
	puntero.visible = apuntando and mostrar_puntero
	estaba_apuntando = apuntando

	acumulador += delta
	if acumulador >= segundos_por_paso:
		acumulador = 0.0
		_paso_automata()

	if hay_cambios:
		_actualizar_textura()
		hay_cambios = false


## Apunta con un rayo (origen y dirección en coordenadas globales).
## Si el rayo toca la pintura, marca ese punto como "apuntado".
func apuntar_rayo(origen: Vector3, direccion: Vector3) -> void:
	var inv := global_transform.affine_inverse()
	var o := inv * origen
	var d := inv.basis * direccion
	if absf(d.z) < 0.0001:
		return
	var t := -o.z / d.z
	if t <= 0.0:
		return                       # la pintura está detrás
	var hit := o + d * t
	var uv := Vector2(hit.x / ancho_m + 0.5, 0.5 - hit.y / alto_m)
	if uv.x < 0.0 or uv.y < 0.0 or uv.x > 1.0 or uv.y > 1.0:
		return
	objetivo = Vector2(hit.x, hit.y)
	ultimo_apuntado_ms = Time.get_ticks_msec()


# ---------------------------------------------------------------- Autómata celular

func _paso_automata() -> void:
	var apuntando := Time.get_ticks_msec() - ultimo_apuntado_ms < 120
	var nuevo_estado := estado.duplicate()
	var nueva_edad := edad.duplicate()
	var tam := imagen_original.get_size()
	var celda_w := float(tam.x) / cols
	var celda_h := float(tam.y) / filas
	var radio_img := radio_pincel_m / ancho_m * float(tam.x)

	for y in filas:
		for x in cols:
			var i := y * cols + x
			match estado[i]:
				VIRGEN:
					# Solo puede activarse si está bajo la mirada.
					# Cuantas más vecinas ya afectadas tenga, más fácil se activa.
					if apuntando:
						var centro := Vector2((x + 0.5) * celda_w, (y + 0.5) * celda_h)
						if centro.distance_to(puntero_img) <= radio_img:
							var n := _vecinas_afectadas(x, y)
							var p := minf(1.0, prob_siembra + influencia_vecinas * n)
							if rng.randf() < p:
								nuevo_estado[i] = ACTIVA
								nueva_edad[i] = 0
								hay_cambios = true
				ACTIVA:
					var e := edad[i] + 1
					if e >= pasos_transicion:
						nuevo_estado[i] = PIXELADA
					else:
						nueva_edad[i] = e
					hay_cambios = true
				# PIXELADA: estado final, no se toca

	estado = nuevo_estado
	edad = nueva_edad


## Cuenta las vecinas (vecindad de Moore, 8 celdas) que ya están ACTIVAS o PIXELADAS.
func _vecinas_afectadas(x: int, y: int) -> int:
	var n := 0
	for dy in range(-1, 2):
		var yy := y + dy
		if yy < 0 or yy >= filas:
			continue
		for dx in range(-1, 2):
			if dx == 0 and dy == 0:
				continue
			var xx := x + dx
			if xx < 0 or xx >= cols:
				continue
			if estado[yy * cols + xx] != VIRGEN:
				n += 1
	return n


# ---------------------------------------------------------------- Textura de celdas

func _actualizar_textura() -> void:
	var total := cols * filas
	var datos := PackedByteArray()
	datos.resize(total * 4)
	for i in total:
		var a := 0
		if estado[i] == PIXELADA:
			a = 255
		elif estado[i] == ACTIVA:
			# el píxel va apareciendo de forma gradual mientras la celda está activa
			a = int(255.0 * float(edad[i] + 1) / float(pasos_transicion))
		var o := i * 4
		datos[o] = colores[i * 3]
		datos[o + 1] = colores[i * 3 + 1]
		datos[o + 2] = colores[i * 3 + 2]
		datos[o + 3] = a
	imagen_overlay.set_data(cols, filas, false, Image.FORMAT_RGBA8, datos)
	textura_overlay.update(imagen_overlay)
