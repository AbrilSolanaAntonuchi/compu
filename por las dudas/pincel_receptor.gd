class_name PincelReceptor
extends Node
## Vive en el celular de las GAFAS. Recibe por WiFi (UDP) hacia dónde apunta el otro celular
## (el "pincel") y le responde con un aviso para que sepa que la conexión funciona.
##
## No hace falta configurar IPs: el pincel emite en broadcast a la red local y este nodo
## escucha en el mismo puerto. Los dos celulares tienen que estar en la misma red WiFi
## (o uno hacer de punto de acceso y el otro conectarse).
##
## Calibración: cuando el pincel avisa "calibrar" (el toque inicial, o dos dedos), lo que estaba
## apuntando en ese momento pasa a significar "el centro de la pintura".

const PUERTO := 47474
const MAGIC := "VRP1"
const TIMEOUT_MS := 1000

## false = se pinta siempre que el pincel apunte a la pintura (como con el mouse).
## true = solo se pinta mientras hay un dedo apoyado en la pantalla del pincel.
@export var pintar_solo_tocando: bool = false

var udp := PacketPeerUDP.new()
var udp_respuesta := PacketPeerUDP.new()
var escuchando := false
var dir_cruda := Vector3(0.0, 0.0, -1.0)   # hacia dónde apunta el pincel, en SU mundo
var calib_recibida := 0
var calib_aplicada := 0
var off_az := 0.0
var off_el := 0.0
var pintando := false
var ultimo_paquete_ms := -100000
var ultima_respuesta_ms := -100000


func _ready() -> void:
	add_to_group("pincel_receptor")
	var err := udp.bind(PUERTO)
	if err != OK:
		push_warning("PincelReceptor: no se pudo abrir el puerto %d (error %d)." % [PUERTO, err])
		return
	escuchando = true


func _process(_delta: float) -> void:
	if not escuchando:
		return
	while udp.get_available_packet_count() > 0:
		var bytes := udp.get_packet()
		var ip := udp.get_packet_ip()
		var puerto := udp.get_packet_port()
		var datos = bytes_to_var(bytes)
		if not (datos is Array) or datos.size() != 6 or datos[0] != MAGIC:
			continue
		var d := Vector3(float(datos[1]), float(datos[2]), float(datos[3]))
		if d.length() < 0.5:
			continue
		dir_cruda = d.normalized()
		calib_recibida = int(datos[4])
		pintando = bool(datos[5])
		ultimo_paquete_ms = Time.get_ticks_msec()

		# Avisarle al pincel que lo estamos recibiendo (como mucho 2 veces por segundo)
		if Time.get_ticks_msec() - ultima_respuesta_ms > 500:
			ultima_respuesta_ms = Time.get_ticks_msec()
			udp_respuesta.set_dest_address(ip, puerto)
			udp_respuesta.put_packet((MAGIC + "OK").to_utf8_buffer())


## true cuando el pincel está mandando datos y ya se calibró al menos una vez.
func conectado() -> bool:
	return escuchando and calib_recibida > 0 \
			and Time.get_ticks_msec() - ultimo_paquete_ms < TIMEOUT_MS


## Texto para el panel de depuración.
func estado() -> String:
	if not escuchando:
		return "sin red (no se pudo abrir el puerto)"
	if Time.get_ticks_msec() - ultimo_paquete_ms > TIMEOUT_MS:
		return "esperando al pincel..."
	if calib_recibida == 0:
		return "conectado, falta calibrar"
	return "OK"


## Dirección de la mirada del pincel en el mundo de las gafas.
## origen = de dónde sale el rayo (la cabeza); centro_pintura = punto al que debe apuntar
## el pincel cuando se calibra.
var sensibilidad := 1.0      # 1.0 = 1:1 con el celular; 3.0 = el puntero se mueve 3 veces más
var ref_az := 0.0
var ref_el := 0.0
var obj_az := 0.0
var obj_el := 0.0

func direccion_mundo(origen: Vector3, dir_referencia: Vector3) -> Vector3:
	if calib_recibida != calib_aplicada:
		var obj := dir_referencia.normalized()
		obj_az = _az(obj)
		obj_el = _el(obj)
		ref_az = _az(dir_cruda)
		ref_el = _el(dir_cruda)
		calib_aplicada = calib_recibida
	var a := obj_az + wrapf(_az(dir_cruda) - ref_az, -PI, PI) * sensibilidad
	var e := clampf(obj_el + (_el(dir_cruda) - ref_el) * sensibilidad, -1.5, 1.5)
	return Vector3(sin(a) * cos(e), sin(e), -cos(a) * cos(e))

# Ángulo horizontal (0 = hacia -Z) y vertical de una dirección
func _az(v: Vector3) -> float:
	return atan2(v.x, -v.z)


func _el(v: Vector3) -> float:
	return asin(clampf(v.y, -1.0, 1.0))
