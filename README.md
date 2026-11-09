# Activación de StarTech USB32HDES (T6 USB Station) en Ubuntu 24.04

Documento de resolución y acciones para poner en funcionamiento el adaptador
USB 3.0 a HDMI **StarTech USB32HDES** en Linux.

> **Nota para Ubuntu 26.04 / kernel 7.x:** el EVDI 1.14.8 incluido en
> `ubuntu_T6_250422.run` **no compila** en el kernel 7.0. `install-usb32hdes.sh`
> detecta el sistema y, en ese caso, compila **EVDI 1.15.1** de DisplayLink y el
> demonio T6 de MCT contra él. Además, EVDI/T6 solo funciona en **X11**;
> Ubuntu 26.04 Budgie arranca en Wayland (labwc), así que hay que usar una
> sesión X11 para que aparezca la pantalla.

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
>
> De ese `.run` se reutiliza el demonio T6 (`evdi_t6.tar.gz`). El EVDI
> empaquetado (`evdi.tar.gz`, versión 1.14.8) solo se usa en el caso conocido
> Ubuntu 24.04 + kernel 6.8; en kernels 7.x se sustituye por EVDI 1.15.1.

### 4.1. Script automático

El repositorio incluye `install-usb32hdes.sh`, que detecta el sistema y aplica
la variante que corresponde:

| Sistema detectado | EVDI usado |
|---|---|
| Ubuntu 24.04 + kernel 6.8 | EVDI incluido en el `.run` de MCT |
| Ubuntu 26.04 / kernel 7.x | **EVDI 1.15.1** de DisplayLink |
| Cualquier otro caso | **EVDI 1.15.1** de DisplayLink |

```bash
chmod +x install-usb32hdes.sh

sudo ./install-usb32hdes.sh install   # detecta, compila e instala
sudo ./install-usb32hdes.sh verify    # comprueba el estado tras el reinicio
sudo ./install-usb32hdes.sh backup    # solo backup de configuración
sudo ./install-usb32hdes.sh uninstall # desinstala y libera el kernel
```

Opciones: `--force` (reinstalar), `--yes` (sin confirmación) y
`--allow-wayland` (permitir la instalación en Wayland, sabiendo que no habrá
salida de vídeo hasta entrar en X11).

Validaciones que aplica antes de instalar:

- Ubuntu >= 24.04, versión de kernel y headers del kernel actual.
- Estado de Secure Boot y sesión gráfica (X11/Wayland). En Wayland se aborta
  salvo que se use `--allow-wayland`.
- Presencia del dispositivo `0711:5601`, espacio en disco y conectividad.
- Dependencias de compilación e instalación.
- Backup de `/etc/modules`, `/etc/modprobe.d`, `libevdi` y units de systemd.
- Integridad del `.run`: contiene `evdi_t6.tar.gz` y su `main.c` acepta
  `0x0711` / `0x5600`.
- Si usa EVDI 1.15.1, elimina `-Werror` del Makefile porque los headers del
  kernel 7.0 generan warnings que de otro modo rompen la compilación.

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

### 5.2. Descargar las fuentes

El script lo hace automáticamente. Si se quiere hacer a mano:

```bash
work="$(mktemp -d /tmp/usb32hdes.XXXXXX)"

curl -fL -o "$work/ubuntu_T6_250422.run" \
  https://raw.githubusercontent.com/carlosmax3D/startech-usba-hdmi-linux-driver/main/ubuntu_T6_250422.run

curl -fL -o "$work/evdi-1.15.1.tar.gz" \
  https://github.com/DisplayLink/evdi/archive/refs/tags/v1.15.1.tar.gz
```

> **No uses rutas fijas en `/tmp`.** Si el fichero ya existe y pertenece a otro
> usuario (por ejemplo, de una ejecución anterior con `sudo`), `curl` falla con
> `Permission denied` / `curl: (23)` debido a `fs.protected_regular=2`.

Verificar que el `.run` contiene el demonio T6 y que su `main.c` soporta
`0x5600`:

```bash
python3 - "$work/ubuntu_T6_250422.run" "$work/t6-inner.tar.gz" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
i = d.find(b'\x1f\x8b')
open(sys.argv[2], 'wb').write(d[i:])
PY
tar tzf "$work/t6-inner.tar.gz"     # debe listar evdi_t6.tar.gz
```

> **Importante:** no ejecutes `ubuntu_T6_250422.run` directamente en Ubuntu
> 26.04 / kernel 7.x. Su EVDI 1.14.8 no compila y el instalador termina con
> `Driver Installation Failed`. Usa el script.

### 5.3. Instalar

```bash
chmod +x install-usb32hdes.sh
sudo ./install-usb32hdes.sh install
```

El script:

1. detecta la distro, la versión de kernel y la sesión gráfica;
2. elige el EVDI adecuado (incluido en MCT para 24.04/6.8, o 1.15.1 para
   kernel 7.x);
3. instala dependencias (`gcc`, `make`, `libturbojpeg`, `libdrm-dev`,
   `libusb-1.0-0-dev`, `libelf-dev`, `build-essential`, ...);
4. compila `evdi.ko`, `libevdi` y el demonio `T6evdi`;
5. copia el módulo a `/lib/modules/$(uname -r)/kernel/drivers/video/`;
6. instala `/usr/sbin/T6evdi`, `/usr/sbin/T6contrl` y `libevdi.so`;
7. crea los servicios `T6evdi`, `T6poweron`, `T6powerdown`;
8. añade `evdi` a `/etc/modules` y `/etc/modprobe.d/evdi.conf`;
9. fija el kernel (`apt-mark hold`) para que una actualización no rompa `evdi`;
10. arranca `evdi` y `T6evdi` si la sesión es X11.

En Wayland el script se detiene con un error explicando que hace falta X11.
Si se quiere instalar igualmente (por ejemplo, para cambiarse a X11 después),
usar `--allow-wayland`; en ese caso no se arranca `T6evdi`.

Tras la instalación se recomienda reiniciar el equipo.

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

> Esta verificación debe hacerse en una **sesión X11**. En Wayland
> `xrandr`/`--listproviders` no verán la salida de EVDI.

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

### 5.7. Si estás en Wayland

Ubuntu 26.04 Budgie arranca por defecto en **Wayland (labwc)** y no incluye una
sesión X11. EVDI/T6 no puede mostrar la pantalla en Wayland.

Opciones:

1. Instalar un escritorio con sesión X11 y elegirlo en la pantalla de login:

   ```bash
   sudo apt install xfce4
   ```

   Cerrar sesión, seleccionar la sesión **Xfce** en SDDM y volver a entrar.
   Después ejecutar `sudo ./install-usb32hdes.sh install`.

2. Instalar con `--allow-wayland` solo deja los archivos preparados; `T6evdi`
   no se arranca y la pantalla no aparecerá hasta usar X11.

3. Si no se quiere usar X11, la alternativa fiable es Ubuntu 24.04 LTS, que es
   el entorno para el que MCT publicó el driver.

---

## 6. Desinstalación / rollback

La forma recomendada con el script:

```bash
sudo ./install-usb32hdes.sh uninstall
```

El `.run` original también incluye modo de desinstalación:

```bash
sudo /tmp/ubuntu_T6_250422.run uninstall
```

Atención: el script de desinstalación del `.run` tiene un typo
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
   `evdi` de DisplayLink y `make`. El `main.c` ya soporta `0x5601`. El script
   `install-usb32hdes.sh` ya hace esto automáticamente y elige EVDI 1.15.1 en
   kernels modernos.
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
