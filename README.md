# Activación de StarTech USB32HDES (T6 USB Station) en Ubuntu 24.04

Documento de resolución y acciones para poner en funcionamiento el adaptador
USB 3.0 a HDMI **StarTech USB32HDES** en Linux.

---

## 1. Resumen del problema

El dispositivo aparece en `lsusb` como:

```
Bus 002 Device 002: ID 0711:5601 Magic Control Technology Corp. T6 USB Station
```

Datos del descriptor USB:

| Campo            | Valor                                  |
|------------------|----------------------------------------|
| VID:PID          | `0711:5601`                            |
| Fabricante       | MCT Corp. (Magic Control Technology)   |
| Producto         | T6 USB Station                         |
| Chip             | Trigger T6-688SL (familia MCT T6)      |
| Clase            | `ff` (vendor-specific)                 |
| Velocidad        | 5000 Mbps (USB 3.0 / SuperSpeed)       |
| Driver en kernel | `[none]`                               |

El adaptador **enumera correctamente** (el hardware funciona), pero su interfaz
es propietaria y **no existe driver en el kernel de Linux**. Por eso no aparece
como pantalla ni se puede usar con `xrandr`.

`lsusb -t` muestra:

```
/:  Bus 002.Port 001: Dev 001, Class=root_hub, Driver=xhci_hcd/4p, 10000M
    |__ Port 004: Dev 002, If 0, Class=Vendor Specific Class, Driver=[none], 5000M
```

---

## 2. Diagnóstico

- **StarTech solo soporta Windows** para el USB32HDES.
- **MCT, fabricante del chip, publica un driver para Ubuntu** de la familia T6.
  Su guía oficial indica que soporta el chip **T6-688SL** (el del USB32HDES) en
  **Ubuntu 24.04.4 LTS**.
- El driver está basado en **EVDI** (DisplayLink) y se compone de:
  - módulo de kernel `evdi.ko`
  - demonio de usuario `T6evdi` (libusb + TurboJPEG)
  - servicios systemd `T6evdi`, `T6poweron`, `T6powerdown`
- El código `main.c` del driver acepta:

  ```c
  if (desc.idVendor == 0x0711 && (desc.idProduct & 0xff00) == 0x5600)
  ```

  Por tanto **`0711:5601` está soportado** (`0x5601 & 0xff00 == 0x5600`).

### Limitaciones conocidas

- **No hay audio por HDMI en Linux** (confirmado por MCT).
- Salida máxima **1080p** (USB32HDES).
- Puede haber latencia/artefactos por compresión USB.
- Driver propietario y poco maduro; puede afectar al gestor de pantallas.

---

## 3. Estado del equipo de referencia

| Elemento              | Estado                                  |
|-----------------------|-----------------------------------------|
| Distro                | Ubuntu 24.04.5 LTS                      |
| Kernel                | `6.8.0-147-generic`                     |
| Sesión gráfica        | **X11** (Budgie / LightDM) — EVDI OK    |
| Secure Boot           | **Desactivado** (no requiere firmar MOK)|
| Headers del kernel    | Instalados                              |
| gcc / make            | gcc 13.3 / make 4.3                     |
| libturbojpeg          | Instalado                               |
| evdi                  | No instalado                            |
| Espacio libre en `/`  | ~31 GB                                  |
| Timeshift             | No instalado                            |

> EVDI funciona en X11. En Wayland el soporte es limitado; este equipo usa X11.

---

## 4. Resolución aplicada

Instalar el **driver oficial de MCT para Ubuntu (T6/EVDI)** desde el mirror
comunitario, que empaqueta el mismo instalador de MCT:

```
https://github.com/carlosmax3D/startech-usba-hdmi-linux-driver
```

Instalador: `ubuntu_T6_250422.run` (script + `evdi.tar.gz` + `evdi_t6.tar.gz`).

> El instalador más reciente de MCT (`ubuntu_T6_260223.run`) se distribuye por
> SharePoint con inicio de sesión. El mirror comunitario es el mismo driver de
> MCT y ya incluye soporte para `0x5601`.

### 4.1. Script automático

El repositorio incluye `install-usb32hdes.sh`, que automatiza las validaciones
y la instalación:

```bash
chmod +x install-usb32hdes.sh

sudo ./install-usb32hdes.sh install   # valida, descarga e instala (reinicia)
sudo ./install-usb32hdes.sh verify    # comprueba el estado tras el reinicio
sudo ./install-usb32hdes.sh backup    # solo backup de configuración
sudo ./install-usb32hdes.sh uninstall # desinstala y libera el kernel
```

Opciones: `--force` (reinstalar) y `--yes` (sin confirmación).

Validaciones que aplica antes de instalar:

- Ubuntu >= 24.04 y headers del kernel actual.
- Estado de Secure Boot y sesión gráfica (X11/Wayland).
- Presencia del dispositivo `0711:5601`, espacio en disco y conectividad.
- Dependencias de compilación e instalación.
- Backup de `/etc/modules`, `/etc/modprobe.d`, `libevdi` y units de systemd.
- Integridad del `.run`: contiene `evdi.tar.gz` y `evdi_t6.tar.gz`, y su
  `main.c` acepta `0x0711` / `0x5600`.

---

## 5. Acciones a aplicar

### 5.1. Backup previo (obligatorio)

```bash
mkdir -p ~/backup-t6
sudo tar czf ~/backup-t6/evdi-backup-$(date +%F).tar.gz \
    /etc/modules \
    /etc/modprobe.d \
    /usr/lib/libevdi* \
    /usr/include/evdi_lib.h \
    /etc/systemd/system/T6*.service \
    2>/dev/null || true
```

Recomendado además: instalar Timeshift y crear un snapshot del sistema.

```bash
sudo apt update && sudo apt install -y timeshift
sudo timeshift --create --comments "antes de driver T6"
```

### 5.2. Descargar el instalador

```bash
curl -fL -o /tmp/ubuntu_T6_250422.run \
  https://raw.githubusercontent.com/carlosmax3D/startech-usba-hdmi-linux-driver/main/ubuntu_T6_250422.run
```

Verificar que contiene los dos tarballs y que el `main.c` soporta `0x5600`:

```bash
python3 - <<'PY'
import sys
d=open('/tmp/ubuntu_T6_250422.run','rb').read()
i=d.find(b'\x1f\x8b')
open('/tmp/t6-inner.tar.gz','wb').write(d[i:])
PY
tar tzf /tmp/t6-inner.tar.gz
```

Debe listar `evdi.tar.gz` y `evdi_t6.tar.gz`.

### 5.3. Instalar

```bash
chmod +x /tmp/ubuntu_T6_250422.run
sudo /tmp/ubuntu_T6_250422.run
```

El instalador:

1. instala dependencias (`gcc`, `make`, `libturbojpeg`, `libdrm-dev`,
   `libusb-1.0-0-dev`, `libelf-dev`, `build-essential`, ...)
2. fija el kernel (`apt-mark hold linux-generic linux-image-generic
   linux-headers-generic`)
3. compila `evdi.ko` y `T6evdi`
4. copia el módulo a `/lib/modules/$(uname -r)/kernel/drivers/video/`
5. crea los servicios `T6evdi`, `T6poweron`, `T6powerdown`
6. añade `evdi` a `/etc/modules`
7. **reinicia el equipo**

### 5.4. Verificación tras el reinicio

```bash
lsmod | grep evdi
systemctl status T6evdi T6poweron T6powerdown --no-pager
journalctl -u T6evdi -b --no-pager | tail -50
dmesg | grep -i evdi
xrandr --listproviders
xrandr --query | grep -E "connected|disconnected"
```

Resultado esperado:

- `evdi` cargado.
- Servicios `T6evdi`/`T6poweron`/`T6powerdown` activos.
- Nueva salida en `xrandr` (normalmente `DVI-I-1-1` o similar).
- `xrandr --listproviders` muestra un proveedor extra.

### 5.5. Configurar la tercera pantalla

Con la aplicación de pantallas de Budgie, o por consola:

```bash
xrandr --query
# sustituir DVI-I-1-1 por la salida real
xrandr --output DVI-I-1-1 --auto --right-of HDMI-1
```

Para persistir la configuración, usar la app de pantallas del escritorio
(Budgie) o un script de arranque con `xrandr`.

### 5.6. Cierre: liberar el kernel

El instalador deja el kernel bloqueado para que la actualización no rompa
`evdi`. Cuando se quiera volver a actualizar:

```bash
sudo apt-mark unhold linux-generic linux-image-generic linux-headers-generic
```

> Si se actualiza el kernel, hay que **recompilar `evdi`** contra el nuevo
> kernel antes de que el adaptador vuelva a funcionar.

---

## 6. Desinstalación / rollback

El propio `.run` incluye modo de desinstalación:

```bash
sudo /tmp/ubuntu_T6_250422.run uninstall
```

Atención: el script de desinstalación tiene un typo
(`/etc/systemmake cleand/system/T6poweron.service`) que puede dejar
`T6poweron.service` sin borrar. Limpiar a mano si hace falta:

```bash
sudo systemctl disable --now T6evdi T6poweron T6powerdown
sudo rm -f /etc/systemd/system/T6evdi.service \
           /etc/systemd/system/T6poweron.service \
           /etc/systemd/system/T6powerdown.service
sudo rm -f /usr/sbin/T6evdi /usr/sbin/T6contrl
sudo rm -f /usr/lib/libevdi.so* /usr/include/evdi_lib.h
sudo rm -f /lib/modules/$(uname -r)/kernel/drivers/video/evdi.ko
sudo depmod -a
```

Restaurar el backup de `/etc/modules` y `/etc/modprobe.d` si es necesario.

---

## 7. Alternativas si no funciona

1. **Compilar desde fuente**: usar `evdi_t6_1/` del repo comunitario con el
   `evdi` de DisplayLink y `make`. El `main.c` ya soporta `0x5601`.
2. **USB-C a HDMI con DP Alt Mode**: sin driver, mejor calidad, si el portátil
   tiene USB-C con salida de vídeo.
3. **Adaptador DisplayLink**: soporte oficial mediante `evdi`.
4. **Devolver el USB32HDES** y usar una de las opciones anteriores.

---

## 8. Referencias

- Driver oficial MCT (Ubuntu 24.04): sección *Download > Driver > Ubuntu driver
  for USB 3.0 Display Adapters* en <https://www.mct.com.tw>
- Guía MCT: `Linux Driver_Ubuntu 24.04.4.pdf` (incluye enlace a
  `ubuntu_T6_260223.run`).
- Mirror comunitario:
  <https://github.com/carlosmax3D/startech-usba-hdmi-linux-driver>
- Repo original:
  <https://github.com/rfxDarth/mobilepixels-linux-driver>
- EVDI (DisplayLink):
  <https://github.com/DisplayLink/evdi>
- Ficha del producto:
  <https://www.startech.com/en-us/display-video-adapters/usb32hdes>
- Base de datos Linux Hardware (sin driver en kernel):
  <https://linux-hardware.org/?id=usb:0711-5601>
