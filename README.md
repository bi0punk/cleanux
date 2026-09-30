# Linux Mantenimiento 1.0.0

Menú CLI para Debian/Ubuntu y distribuciones basadas en Red Hat (Fedora, RHEL, Rocky, AlmaLinux). Requiere Bash 4.3+, GNU `find`, `stat`, `realpath` e `id`. Ejecutar como **usuario normal**; `sudo` se usa únicamente si se habilita una tarea del sistema.

## Inicio

```bash
chmod +x linux_mantenimiento.sh
./linux_mantenimiento.sh --menu
./linux_mantenimiento.sh --scan
./linux_mantenimiento.sh --run
./linux_mantenimiento.sh --health
```

El menú permite activar tareas, modificar antigüedad, agregar o quitar carpetas, hacer una vista previa y revisar disco, inodos, RAM, carga y servicios fallidos. `--run` vuelve a escanear y exige escribir `LIMPIAR`; `--run --yes` es la confirmación explícita para automatización. No programes ejecuciones automáticas hasta revisar la configuración y un escaneo real.

## Tareas

| ID | Estado inicial | Acción |
| --- | --- | --- |
| `thumbs` | Activa | Archivos de miniaturas en `~/.cache/thumbnails` con más de 30 días. |
| `cache` | Activa | Archivos en `~/.cache` con más de 60 días; excluye miniaturas y pip, que tienen interruptores propios. |
| `tmp` | Inactiva | Solo archivos regulares del usuario en `/tmp` y `/var/tmp` con más de 14 días. |
| `pip` | Inactiva | Caché de pip con más de 60 días. |
| `history` | Inactiva | Vacía el contenido de `~/.bash_history` y `~/.zsh_history`. |
| `packages` | Inactiva | `apt-get autoclean` o `dnf clean packages`, según la distribución detectada. |
| `journal` | Inactiva | `journalctl --vacuum-time=30d` (solo diarios archivados). |

`packages` y `journal` no tienen cálculo exacto de ahorro previo: sus propias herramientas deciden el resultado. El escaneo informa ese límite y no los incluye en el total de bytes.

## Configuración rápida

```bash
./linux_mantenimiento.sh --list
./linux_mantenimiento.sh --enable tmp
./linux_mantenimiento.sh --set-days tmp 21
./linux_mantenimiento.sh --enable packages
./linux_mantenimiento.sh --add-path "$HOME/.local/state/mi-app/cache" 30
./linux_mantenimiento.sh --scan
./linux_mantenimiento.sh --remove-path 0
```

La carpeta personalizada debe existir dentro de `HOME`, no ser un enlace simbólico y no estar bajo ubicaciones personales protegidas como `Documents`, `Downloads`, `Desktop`, `Pictures`, `.ssh`, `.gnupg` o `.config`. Se eliminan solo **archivos regulares antiguos** dentro de ella, no la carpeta ni sus subcarpetas vacías. Agrega únicamente carpetas que sepas regenerar. La configuración se guarda con permisos privados en `${XDG_CONFIG_HOME:-$HOME/.config}/linux-mantenimiento/config`; se lee como datos, nunca como comandos de Bash.

## Límites operativos

- El escaneo usa fechas de modificación (`mtime`) y tamaño lógico. Los bytes realmente recuperados pueden diferir por compresión, enlaces duros y sistemas de archivos.
- No sigue enlaces simbólicos ni atraviesa montajes al enumerar. Antes de actuar comprueba propietario, inode, dispositivo, tamaño y fecha del archivo; omite los que cambiaron. Como ocurre con cualquier herramienta Bash que opera sobre rutas, un proceso que modifica las rutas simultáneamente puede crear una carrera entre la comprobación y `rm`; no ejecutes tareas personalizadas en directorios compartidos con usuarios no confiables.
- Los archivos abiertos por procesos pueden seguir ocupando espacio hasta que el proceso termine. Los shells abiertos pueden reescribir su historial al cerrar.
- El máximo por ejecución es 50.000 candidatos para limitar el uso de RAM; si se alcanza, el escaneo lo avisa y la siguiente ejecución continúa con los restantes.
- No ejecuta `autoremove`, no vacía la papelera, no borra logs activos y no actualiza ni instala paquetes.
- Para respaldo o limpieza con retención estricta, define un procedimiento específico para esos datos antes de activarlo en servidores de producción.

## Verificación local

```bash
bash -n linux_mantenimiento.sh
./tests/run.sh
./linux_mantenimiento.sh --help
```

La integración continua ejecuta sintaxis, ShellCheck y la suite local en Ubuntu. Para reproducir el lint completo localmente instala `shellcheck` y ejecuta:

```bash
shellcheck linux_mantenimiento.sh tests/run.sh
```

Consulta de comandos: [GNU find](https://www.man7.org/linux/man-pages/man1/find.1.html), [APT](https://manpages.debian.org/bookworm/apt/apt-get.8), [journalctl](https://www.freedesktop.org/software/systemd/man/latest/journalctl.html). Para DNF, usa la documentación de tu distribución instalada (`man dnf`).
