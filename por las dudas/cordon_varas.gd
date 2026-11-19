class_name CordonVaras
extends Node3D
## Cordón de varas con cuerda roja, generado por código (sin archivos externos).
##
## Arma un rectángulo de postes de metal (base redonda, cuello acampanado y bola arriba)
## unidos por cuerdas rojas que cuelgan. Si un lado es largo, agrega postes intermedios.
##
## Se usa creando el nodo, configurándolo y agregándolo a la escena (se construye en _ready):
##   var cordon := CordonVaras.new()
##   cordon.centro_xz = Vector2(0, -1.7)
##   add_child(cordon)
##
## Las medidas están en las unidades del nodo padre (en revelar_espacio.gd, las del diorama).

@export var centro_xz: Vector2 = Vector2(0.0, -1.7)   # centro del rectángulo (X, Z)
@export var mitad_x: float = 4.2                      # mitad del ancho
@export var mitad_z: float = 4.8                      # mitad del fondo
@export var separacion_max: float = 4.5               # distancia máxima entre postes
@export var altura_poste: float = 3.2                 # altura total (hasta el centro de la bola)
@export var caida_cuerda: float = 0.55                # cuánto cuelga la cuerda en el medio
@export var radio_cuerda: float = 0.09
@export var color_cuerda: Color = Color(0.78, 0.03, 0.05)
@export var color_metal: Color = Color(0.82, 0.84, 0.88)

const RADIO_POSTE := 0.11
const RADIO_BOLA := 0.24
const LADOS_POSTE := 28
const LADOS_CUERDA := 10
const TRAMOS_CUERDA := 24

var mat_metal: StandardMaterial3D
var mat_cuerda: StandardMaterial3D
var mesh_poste: ArrayMesh
var mesh_bola: SphereMesh
var mesh_terminal: SphereMesh


func _ready() -> void:
	_crear_materiales()
	_crear_meshes()
	var puntos := _puntos_del_perimetro()
	for p in puntos:
		_poner_poste(p)
	for i in puntos.size():
		_poner_cuerda(puntos[i], puntos[(i + 1) % puntos.size()])


# ---------------------------------------------------------------- Distribución

func _puntos_del_perimetro() -> Array[Vector3]:
	var x0 := centro_xz.x - mitad_x
	var x1 := centro_xz.x + mitad_x
	var z0 := centro_xz.y - mitad_z
	var z1 := centro_xz.y + mitad_z
	var esquinas: Array[Vector3] = [
		Vector3(x0, 0.0, z0), Vector3(x1, 0.0, z0),
		Vector3(x1, 0.0, z1), Vector3(x0, 0.0, z1),
	]
	var resultado: Array[Vector3] = []
	for i in 4:
		var a := esquinas[i]
		var b := esquinas[(i + 1) % 4]
		var n := maxi(1, ceili(a.distance_to(b) / separacion_max))
		for k in n:
			resultado.append(a.lerp(b, float(k) / float(n)))
	return resultado


# ---------------------------------------------------------------- Materiales y mallas

func _crear_materiales() -> void:
	mat_metal = StandardMaterial3D.new()
	mat_metal.albedo_color = color_metal
	mat_metal.metallic = 0.55
	mat_metal.roughness = 0.3

	mat_cuerda = StandardMaterial3D.new()
	mat_cuerda.albedo_color = color_cuerda
	mat_cuerda.roughness = 0.85
	mat_cuerda.rim_enabled = true      # brillo suave en el borde, como el terciopelo
	mat_cuerda.rim = 0.35
	mat_cuerda.rim_tint = 0.6


func _crear_meshes() -> void:
	var h := altura_poste
	# Perfil del poste (radio, altura): disco, base acampanada, anillos y caño
	var perfil: Array[Vector2] = [
		Vector2(0.95, 0.00), Vector2(1.00, 0.04), Vector2(0.96, 0.09), Vector2(0.55, 0.14),
		Vector2(0.42, 0.22), Vector2(0.40, 0.40), Vector2(0.33, 0.70), Vector2(0.22, 0.95),
		Vector2(0.14, 1.15), Vector2(RADIO_POSTE, 1.30),
		Vector2(0.16, 1.32), Vector2(0.16, 1.40), Vector2(RADIO_POSTE, 1.42),
		Vector2(RADIO_POSTE, h - 0.50),
		Vector2(0.15, h - 0.48), Vector2(0.15, h - 0.38), Vector2(RADIO_POSTE, h - 0.36),
		Vector2(RADIO_POSTE, h - 0.15),
	]
	mesh_poste = _torno(perfil, LADOS_POSTE)
	mesh_poste.surface_set_material(0, mat_metal)

	mesh_bola = SphereMesh.new()
	mesh_bola.radius = RADIO_BOLA
	mesh_bola.height = RADIO_BOLA * 2.0
	mesh_bola.material = mat_metal

	mesh_terminal = SphereMesh.new()
	mesh_terminal.radius = radio_cuerda * 1.5
	mesh_terminal.height = radio_cuerda * 3.0
	mesh_terminal.radial_segments = 12
	mesh_terminal.rings = 6
	mesh_terminal.material = mat_metal


## Gira un perfil (radio, altura) alrededor del eje Y para formar una pieza redonda.
func _torno(perfil: Array[Vector2], lados: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for j in perfil.size() - 1:
		for i in lados:
			var a0 := TAU * float(i) / float(lados)
			var a1 := TAU * float(i + 1) / float(lados)
			var pa := Vector3(perfil[j].x * cos(a0), perfil[j].y, perfil[j].x * sin(a0))
			var pb := Vector3(perfil[j + 1].x * cos(a0), perfil[j + 1].y, perfil[j + 1].x * sin(a0))
			var pc := Vector3(perfil[j + 1].x * cos(a1), perfil[j + 1].y, perfil[j + 1].x * sin(a1))
			var pd := Vector3(perfil[j].x * cos(a1), perfil[j].y, perfil[j].x * sin(a1))
			for v in [pa, pd, pc, pa, pc, pb]:
				st.add_vertex(v)
	st.generate_normals()
	return st.commit()


# ---------------------------------------------------------------- Piezas

func _poner_poste(base: Vector3) -> void:
	var poste := MeshInstance3D.new()
	poste.mesh = mesh_poste
	poste.position = base + Vector3(0.0, 0.01, 0.0)   # apenas sobre el piso para no parpadear
	add_child(poste)

	var bola := MeshInstance3D.new()
	bola.mesh = mesh_bola
	bola.position = poste.position + Vector3(0.0, altura_poste, 0.0)
	add_child(bola)


func _poner_cuerda(base_a: Vector3, base_b: Vector3) -> void:
	var alto := altura_poste - 0.45
	var pa := base_a + Vector3(0.0, alto, 0.0)
	var pb := base_b + Vector3(0.0, alto, 0.0)
	var dir := (pb - pa).normalized()
	# La cuerda arranca justo afuera del caño; ahí va un terminal metálico
	var ini := pa + dir * (RADIO_POSTE + radio_cuerda * 1.2)
	var fin := pb - dir * (RADIO_POSTE + radio_cuerda * 1.2)

	var cuerda := MeshInstance3D.new()
	cuerda.mesh = _tubo(ini, fin)
	add_child(cuerda)

	for extremo in [ini, fin]:
		var t := MeshInstance3D.new()
		t.mesh = mesh_terminal
		t.position = extremo
		add_child(t)


## Tubo rojo que cuelga entre dos puntos (curva tipo parábola).
func _tubo(ini: Vector3, fin: Vector3) -> ArrayMesh:
	var centros: Array[Vector3] = []
	for k in TRAMOS_CUERDA + 1:
		var t := float(k) / float(TRAMOS_CUERDA)
		centros.append(ini.lerp(fin, t) + Vector3.DOWN * caida_cuerda * 4.0 * t * (1.0 - t))

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for k in TRAMOS_CUERDA:
		var f0 := _anillo(centros, k)
		var f1 := _anillo(centros, k + 1)
		for m in LADOS_CUERDA:
			var m1 := (m + 1) % LADOS_CUERDA
			var pa: Vector3 = f0[m]
			var pb: Vector3 = f1[m]
			var pc: Vector3 = f1[m1]
			var pd: Vector3 = f0[m1]
			for v in [pa, pd, pc, pa, pc, pb]:
				st.add_vertex(v)
	st.generate_normals()
	var malla := st.commit()
	malla.surface_set_material(0, mat_cuerda)
	return malla


## Puntos del círculo (sección de la cuerda) en la posición k del recorrido.
func _anillo(centros: Array[Vector3], k: int) -> Array[Vector3]:
	var k0 := maxi(k - 1, 0)
	var k1 := mini(k + 1, centros.size() - 1)
	var tangente := (centros[k1] - centros[k0]).normalized()
	var lado := tangente.cross(Vector3.UP).normalized()
	var arriba := lado.cross(tangente).normalized()
	var puntos: Array[Vector3] = []
	for m in LADOS_CUERDA:
		var f := TAU * float(m) / float(LADOS_CUERDA)
		puntos.append(centros[k] + (lado * cos(f) + arriba * sin(f)) * radio_cuerda)
	return puntos
