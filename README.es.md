<p align="center"><img src="packaging/AppIcon.png" width="128" alt="Icono de EVE-O Preview for macOS"></p>

# EVE-O Preview for macOS

[English](README.md) | [简体中文](README.zh-CN.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Русский](README.ru.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | **Español**

Esta traducción es automática; si difiere del [README en inglés](README.md), prevalece la versión en inglés.

EVE-O Preview for macOS muestra una miniatura en directo de cada cliente de EVE Online en ejecución. Haz clic en una miniatura o pulsa un atajo global para cambiar a ese cliente.

Es una reimplementación nativa en Swift, para macOS, de las funciones de [EveOPlus/eve-o-preview](https://github.com/EveOPlus/eve-o-preview) (Windows, GPL-3.0). No porta el código C# del proyecto original, y su interfaz y su formato de configuración difieren de los del proyecto original.
Se distribuye bajo la GNU General Public License versión 3 o cualquier versión posterior (GPL-3.0-or-later), de acuerdo con los identificadores SPDX de los archivos fuente; el proyecto original se distribuye bajo la GPL-3.0. Consulta [LICENSE](LICENSE) para ver el texto completo.

Este repositorio empezó como un fork en GitHub de EveOPlus/eve-o-preview y se trasladó a un repositorio independiente para la v1.0. Es un proyecto independiente: no comparte código con la versión para Windows y no lo mantienen los autores del proyecto original.

## Funciones

- Detección de clientes: las miniaturas se actualizan automáticamente cuando un cliente se abre, se cierra o cambia de nombre tras iniciar sesión.
- Miniaturas en directo: un flujo de ScreenCaptureKit por cliente, con tamaño y frecuencia de fotogramas ajustables.
- Paneles de miniatura: nunca toman el foco, aparecen en todos los Spaces y, opcionalmente, pueden mantenerse en primer plano. Por omisión tienen un borde gris claro de 2 puntos para distinguir fácilmente las miniaturas contiguas; el color y el grosor son ajustables, y el borde se puede desactivar.
- Cambio: haz clic con el botón izquierdo en una miniatura para cambiar a su cliente; Control + clic lo minimiza. El menú del clic derecho ofrece Minimizar, Minimizar todos, Omitir en el ciclo, Ocultar esta miniatura y Restablecer tamaño predeterminado.
- Superposiciones: el nombre del personaje como título, un borde de resaltado en el cliente activo (el color se puede configurar por personaje; sustituye al borde gris claro mientras se muestra) y una marca de omitir en el ciclo.
- Zoom al pasar el puntero (9 puntos de anclaje) y opacidad.
- Visibilidad: ocultar la miniatura del cliente activo; ocultar cuando EVE no está en primer plano (con retardo); ocultar por personaje; ocultar todas.
- Disposición: arrastra para mover y redimensionar, con ajuste a otras miniaturas y a los bordes de la pantalla, y bloqueo opcional de la disposición. La posición y el tamaño se guardan por personaje; los clientes en la pantalla de inicio de sesión usan una posición inicial aparte.
- Grupos de ciclo: atajos hacia delante y hacia atrás, omisión durante la sesión actual; atajos por personaje; un atajo para recorrer los clientes en la pantalla de inicio de sesión; atajos para ocultar todas las miniaturas y minimizar todos los clientes. Los atajos pueden usar los botones central y laterales del ratón, y cada atajo puede ser global o solo para EVE.
- Alertas de combate (desactivadas por omisión): leen los registros del juego y hacen parpadear la miniatura de un personaje cuando lo atacan.
- Superposición de inteligencia (desactivada por omisión): lee los registros de chat de los canales de inteligencia que elijas y muestra, para el personaje de la ventana de EVE en primer plano, en qué sistemas se informa de hostiles, a cuántos saltos están, cuántos son y qué naves llevan (consulta [Superposición de inteligencia](#superposición-de-inteligencia)).
- Superposición de traducción del chat (desactivada por omisión): traduce a tu idioma los mensajes en otros idiomas de los canales que elijas, con un servicio de modelos que tú eliges y tu propia clave de API (consulta [Traducción del chat](#traducción-del-chat)).
- Perfiles: crear, duplicar, renombrar, eliminar y cambiar.
- Actualizaciones: busca nuevas versiones en GitHub y las instala desde la propia app tras verificar la descarga y su firma de código (consulta [Actualizaciones](#actualizaciones)).
- Informes de problemas: genera un zip de diagnóstico anonimizado y abre un issue de GitHub ya rellenado; tras un cierre inesperado, el siguiente arranque ofrece informar de él (consulta [Informar de un problema](#informar-de-un-problema)).
- Un icono en la barra de menús en lugar del icono de la bandeja de Windows.
- Una ventana de ajustes de 10 páginas: Clientes, Miniaturas, Cambio y atajos, Alertas, Inteligencia, Traducción, Perfiles, General, Permisos y Acerca de.
- Idiomas de la interfaz: inglés (predeterminado), chino, ruso, japonés, coreano, francés, alemán y español. Cámbialo en la página General o elige “Según el sistema”; el cambio surte efecto al instante. Las traducciones al ruso, japonés, coreano, francés, alemán y español son automáticas; se agradecen las correcciones.

## Funciones del proyecto original no portadas

| Función del proyecto original | Motivo |
| --- | --- |
| Limitación de fotogramas y silenciado selectivo (inyección de Robin) | El proyecto original inyecta una DLL en procesos de Windows; macOS no tiene un mecanismo público equivalente |
| Afinidad de CPU | Depende de los CPU Sets de Windows; Apple Silicon no tiene una API pública para fijar un proceso a núcleos concretos |
| Augments del registro de combate: cifras de daño, DPS, cantidades de reparación, superposición del sistema, datos estáticos de FC | Un subsistema grande e independiente, fuera de “previsualizar y cambiar”; solo se portó “parpadear al recibir un ataque” |
| Temas, interfaz heredada, estilos personalizados del menú del clic derecho | La versión para macOS sigue el aspecto del sistema |
| Modo de captura de compatibilidad (`PrintWindow`) | ScreenCaptureKit es el único método de captura |
| Hook de teclado de bajo nivel | Los atajos de teclado usan los atajos globales de Carbon; solo se crea un event tap del ratón cuando hay un botón del ratón asignado |

Las regiones con acoplamiento mediante arrastrar y soltar, la selección múltiple y el movimiento en grupo, deshacer, las guías de ajuste, la importación de configuraciones de Windows y el arranque al iniciar sesión están previstos para después de la v1.

## Requisitos

- macOS 14 o posterior, en Apple Silicon o Intel. El dmg de cada versión contiene un binario universal.
- Los clientes de EVE funcionan mejor en modo ventana. Los clientes en pantalla completa nativa se admiten desde la 1.1.1 (las miniaturas se muestran encima mientras “Mantener las miniaturas en primer plano” está activado), pero cada uno ocupa su propio Space, así que al cambiar a uno se reproduce la animación de transición entre Spaces.
- Para compilar desde el código fuente se necesita Xcode o las Command Line Tools (Swift 6).

## Instalación

### Descargar una versión

1. Descarga `EVE-O-Preview-<version>.dmg` desde la página [Releases](https://github.com/deletexiumu/eve-o-preview-macos/releases).
2. Abre el dmg y arrastra `EVE-O Preview.app` a la carpeta Aplicaciones.
3. Abre la app. Su icono aparece en la barra de menús y, en el primer arranque, la ventana de ajustes se abre en la página Permisos.

Las compilaciones publicadas están firmadas con un certificado autofirmado propio del proyecto y no están notarizadas, porque el proyecto no tiene un Apple Developer ID. En el primer arranque, macOS bloquea la app con un mensaje que indica que no puede verificar al desarrollador. Para abrirla:

1. Abre Ajustes del Sistema > Privacidad y seguridad.
2. Desplázate hacia abajo hasta el mensaje sobre EVE-O Preview, haz clic en “Abrir igualmente” y confirma.

Si macOS indica que la app “está dañada y no se puede abrir”, o como alternativa a los pasos anteriores, elimina el atributo de cuarentena en Terminal:

```sh
xattr -dr com.apple.quarantine "/Applications/EVE-O Preview.app"
```

**Nota:** todas las versiones se firman con el mismo certificado, así que macOS conserva los permisos de Grabación de pantalla y Accesibilidad al actualizar. Si los permisos dejan de funcionar tras una actualización, restablécelos con los comandos `tccutil` del final de [Permisos](#permisos) y vuelve a concederlos.

A partir de la 1.1.0 la app puede actualizarse sola (consulta [Actualizaciones](#actualizaciones)). La versión 1.0.0 no tiene actualizador, así que instala la 1.1.0 a mano una vez: descarga el dmg y sustituye la app en Aplicaciones. Los permisos se conservan, porque la 1.0.0 y las posteriores están firmadas con el mismo certificado.

Cada versión incluye también el código fuente en `.tar.gz` y `.zip`, y un archivo `SHA256SUMS.txt`. Para verificar las descargas, ejecuta `shasum -a 256 --ignore-missing -c SHA256SUMS.txt` en la carpeta de descargas.

### Compilar desde el código fuente

1. En la raíz del repositorio, ejecuta `scripts/build-app.sh`. El script compila la configuración release y después ensambla y firma `dist/EVE-O Preview.app`.
2. Arrastra `dist/EVE-O Preview.app` a la carpeta Aplicaciones.
3. Abre la app.

El script lee estas variables de entorno:

| Variable | Función | Valor predeterminado |
| --- | --- | --- |
| `VERSION` | Número de versión que se escribe en `Info.plist` | El contenido del archivo `VERSION` |
| `SIGN_IDENTITY` | Identidad de firma de código | `EVEO Preview Dev` si está en el llavero; si no, ad hoc (`-`) |
| `UNIVERSAL` | `1` compila arm64 y x86_64 por separado y los combina con `lipo` en un binario universal | Sin definir: solo la arquitectura nativa |

Si existe `packaging/AppIcon.png`, el script lo usa para generar el icono de la app.

`scripts/package-release.sh` ejecuta `build-app.sh` y después escribe el dmg, los archivos de código fuente y `SHA256SUMS.txt` en `dist/release/`. La CI usa este script.

## Permisos

La app usa los permisos del sistema que se indican a continuación, todos concedidos en Ajustes del Sistema > Privacidad y seguridad. La página Permisos de la ventana de ajustes muestra su estado, con botones para solicitarlos y enlaces a Ajustes del Sistema.

| Permiso | Para qué se usa | Sin él |
| --- | --- | --- |
| Grabación de pantalla | Capturar las ventanas de los clientes y leer los títulos de las ventanas | Las miniaturas muestran un texto provisional; si además falta Accesibilidad, no se pueden leer los títulos y los clientes aparecen como `EVE (PID)` |
| Accesibilidad | Restaurar, traer al frente y minimizar las ventanas de los clientes, leer los títulos de las ventanas, interceptar los atajos del ratón | Solo se puede activar el proceso del cliente, así que las ventanas minimizadas no se pueden restaurar; Minimizar y Minimizar todos están desactivados; los atajos del ratón no funcionan, los de teclado sí |
| Carpeta Documentos | Las alertas de combate leen `~/Documents/EVE/logs/Gamelogs`; las superposiciones de inteligencia y de traducción leen `~/Documents/EVE/logs/Chatlogs`, y la de inteligencia también lee los registros del juego para saber tu ubicación | Solo se solicita al activar una de estas funciones o al hacer clic en “Actualizar” en el menú “Añadir desde los registros”; si se deniega, la página de esa función muestra el motivo y las demás funciones no se ven afectadas |
| Red local (macOS 15 y posterior) | Conectar con un servicio de traducción en otro ordenador de la red local, por ejemplo Ollama | Solo se solicita cuando el servicio de traducción se ejecuta en otro ordenador de la red local, no para este Mac ni para servicios públicos; haz clic en “Probar” en la página Traducción para que la petición aparezca antes. Si se deniega, las solicitudes a ese ordenador fallan con un error de red. No aparece en la página Permisos |

Tras conceder Grabación de pantalla, normalmente hay que reiniciar la app para que surta efecto; la página Permisos tiene un botón Reiniciar. Accesibilidad surte efecto al instante.

### Firmar con un certificado autofirmado

macOS identifica una app por su firma de código cuando registra los permisos. Una firma ad hoc no tiene una identidad estable, así que tras cada compilación macOS trata la app como si fuera otra y se pierden ambos permisos. Si la compilas tú, usa un certificado autofirmado:

1. Abre Acceso a Llaveros y elige Acceso a Llaveros > Asistente de Certificados > Crear un certificado.
2. Escribe el nombre `EVEO Preview Dev`, ajusta Tipo de identidad a “Raíz autofirmada” y Tipo de certificado a “Firma de código”, y créalo.
3. Ejecuta `scripts/build-app.sh`. El script usa este certificado automáticamente cuando lo encuentra en el llavero; también puedes ejecutar `SIGN_IDENTITY="EVEO Preview Dev" scripts/build-app.sh`.
4. Si macOS pregunta si `codesign` puede usar la clave privada del llavero, elige “Permitir siempre”.

Si los registros de permisos quedan en mal estado, ejecuta estos dos comandos y vuelve a conceder los permisos:

```sh
tccutil reset ScreenCapture io.github.deletexiumu.eveopreview-macos
tccutil reset Accessibility io.github.deletexiumu.eveopreview-macos
```

## Uso

### Gestos de las miniaturas

Al pulsar el botón izquierdo se cambia de inmediato, sin esperar a soltarlo, así que para mover y redimensionar se arrastra con el botón derecho o con Opción + botón izquierdo.

| Acción | Gesto |
| --- | --- |
| Cambiar al cliente | Pulsar el botón izquierdo |
| Minimizar el cliente | Control + pulsar el botón izquierdo |
| Abrir el menú | Clic derecho (moviendo menos de 4 puntos entre pulsar y soltar) |
| Mover | Arrastrar con el botón derecho, u Opción + arrastrar con el botón izquierdo |
| Redimensionar | El mismo gesto que para mover, empezando a menos de 12 puntos del borde de la miniatura |
| Desactivar temporalmente el ajuste | Mantén pulsada Mayúsculas al arrastrar; al redimensionar, Mayúsculas también mantiene la proporción |

Con “Bloquear disposición” activado, mover y redimensionar no hacen nada; cambiar, minimizar y el menú siguen funcionando.

### Atajos

Graba los atajos en la página Cambio y atajos de la ventana de ajustes: haz clic en un botón y pulsa una combinación de teclas o un botón del ratón. Esc cancela y Eliminar borra. Una acción puede tener varias asignaciones.

- Grupos de ciclo: cada grupo tiene atajos hacia delante y hacia atrás que cambian, por orden, entre los personajes del grupo que están conectados y no omitidos, y vuelven al principio al llegar al final.
- Atajos por personaje: cambian al cliente de ese personaje.
- Atajos generales: mostrar u ocultar todas las miniaturas, minimizar todos los clientes y recorrer los clientes en la pantalla de inicio de sesión.

Los atajos de teclado deben incluir Control, Opción o Comando; F1–F20 y los números del teclado numérico pueden usarse solos. Se rechazan las combinaciones del sistema como Cmd+Tab, Cmd+Espacio y Cmd+Q. Cuando un atajo tiene un problema, la ventana de ajustes muestra el motivo junto a él.

Atajos del ratón:

- Se pueden grabar los botones central y laterales (escritos como `Mouse3`–`Mouse32` en la configuración), opcionalmente con modificadores, como `ctrl+Mouse4`. Los botones izquierdo y derecho no se pueden asignar.
- Cuando se activa un atajo, ese clic (pulsar, arrastrar y soltar) no se pasa a la app en primer plano, así que una acción del juego asignada al mismo botón no se ejecuta.
- Los atajos del ratón necesitan el permiso de Accesibilidad.

Ámbito:

- Cada atajo puede ser “Global” o “Solo en EVE”, escrito como el sufijo `@global` o `@game` en la configuración. Un atajo sin sufijo sigue el ámbito predeterminado del perfil.
- Un atajo “Solo en EVE” solo funciona mientras un cliente de EVE está en primer plano. En otras apps, la pulsación se pasa a esa app como de costumbre.
- Los atajos del ratón recién grabados usan Solo en EVE por omisión, para que los botones laterales no se intercepten en todas las apps.
- “Atajos solo en EVE”, en el menú de la barra de menús, alterna el ámbito predeterminado.

### Alertas de combate

Actívalas en la página Alertas de la ventana de ajustes. La app lee entonces los registros del juego que los clientes escriben en `~/Documents/EVE/logs/Gamelogs`, asocia cada registro a un personaje por el oyente (listener) que figura en su cabecera y hace parpadear durante 3 segundos el borde y la imagen de la miniatura de un personaje cuando lo atacan.

- El cliente de EVE debe tener activado el registro del juego (lo está por omisión).
- Por omisión, los ataques fallidos también activan una alerta; esto se puede desactivar. El daño mínimo, el color del parpadeo y la duración son configurables.
- Con “Ocultar las miniaturas si EVE no está en primer plano” activado, la miniatura de un personaje atacado se muestra temporalmente.
- Con “Reducir movimiento” activado en Ajustes del Sistema, el parpadeo se sustituye por un resaltado fijo.
- La app solo lee los registros. Nunca los escribe ni los modifica, y no envía ninguna entrada al juego.
- La primera vez, macOS pide acceso a la carpeta Documentos. Si tus registros están en otro sitio, elige la carpeta en la página Alertas.
- El formato de registro del cliente chino se ha comprobado con registros reales. Las líneas de daño en japonés y ruso se han comprobado con registros reales de clientes (las muestras grabadas del proyecto original); sus líneas de fallo solo se deducen de plantillas. Inglés, alemán, francés, español y coreano se deducen de las plantillas del proyecto original y no se han comprobado con registros reales.

### Superposición de inteligencia

Actívala con “Mostrar superposición de inteligencia” en la página Inteligencia de la ventana de ajustes, o con Mostrar superposición de inteligencia en el menú de la barra de menús. La app lee entonces los registros de chat que los clientes escriben en `~/Documents/EVE/logs/Chatlogs`, junto a la carpeta de registros del juego elegida en la página Alertas. Cada línea de la superposición es un mensaje de tus canales de inteligencia: su antigüedad, cada sistema con su nivel de seguridad y su distancia en saltos desde tu ubicación, el número de hostiles, las naves y los nombres de los pilotos.

- El cliente de EVE debe estar configurado para guardar el chat en un archivo.
- Canales: elige “Añadir desde los registros” para escoger entre los canales de tus registros de chat recientes (cada uno indica cuántos de tus personajes están en él), o escribe el nombre de un canal y pulsa Retorno. La carpeta de registros solo se lee cuando la función está activada o cuando haces clic en “Actualizar” en el menú “Añadir desde los registros”; mientras la función está desactivada, el menú muestra al principio solo “Actualizar” (y, en la página Traducción, los canales integrados). Hasta 16 canales. Las conversaciones privadas nunca se leen ni se muestran en la lista.
- Al activarla, la superposición se llena con los mensajes de los últimos 30 minutos (“Conservar los últimos”, 5–120 minutos); las líneas más antiguas desaparecen.
- Ubicación: los saltos se cuentan desde el sistema donde está el personaje activo. La app lo obtiene de las líneas de salto y de desatraque de los registros del juego y de los mensajes de cambio de sistema del registro de chat Local. Si no hay ninguno de los dos, escribe un nombre de sistema para ese personaje en “Mi ubicación” y pulsa Retorno; un nombre desconocido muestra “No se encuentra el sistema”. El siguiente salto reemplaza una ubicación manual, y una ubicación manual se conserva al reiniciar. Un personaje sin ninguna ubicación cuenta los saltos desde el “Sistema de referencia”.
- “Contar hasta” limita el número de saltos (1–30, 15 por omisión). “Resaltar a menos de” resalta un mensaje cuando un sistema informado está a ese número de saltos o menos (5 por omisión; 0 lo desactiva). “Mostrar el texto original” añade el remitente y el mensaje en una segunda línea.
- Los nombres de sistemas y naves se muestran en el idioma de la interfaz.
- Los nombres de pilotos son lo que queda de un mensaje después de reconocer sistemas, naves y cantidades, así que los nombres con espacios que van seguidos son ambiguos. Con “Comprobación de nombres en línea (ESI)” activada (por omisión), la app pregunta a la ESI de CCP cuáles de esas palabras son nombres reales de personajes y los separa en consecuencia (consulta [Privacidad](#privacidad)). Una coincidencia solo indica que existe un personaje con ese nombre, no que sea el aludido. Un nombre encontrado tiene un enlace a zKillboard en “Abrir en el navegador” del menú contextual. “Vaciar caché de nombres” borra los nombres guardados.

### Traducción del chat

Actívala con “Mostrar superposición de traducción” en la página Traducción, o con Mostrar superposición de traducción en el menú de la barra de menús. Traduce los mensajes de los canales elegidos que aún no están en el idioma de destino.

1. Elige los canales como para la superposición de inteligencia; “Añadir desde los registros” también muestra los canales integrados Local, Corporación, Alianza y Flota.
2. En “Traducir al”, elige un idioma, o “Igual que el idioma de la interfaz” (por omisión).
3. Elige un “Servicio”: DeepSeek (por omisión), Claude (Anthropic), OpenAI, Qwen (DashScope), Kimi (Moonshot), Ollama u “Otro (compatible con OpenAI)”. “Dirección de la API” y “Nombre del modelo” muestran los valores del preajuste; escribe otros para reemplazarlos.
4. Pega tu clave de API y haz clic en “Guardar”. La clave se guarda en el llavero de macOS; “Eliminar clave” la borra. Ollama no necesita clave.
5. Haz clic en “Probar” para traducir una frase de ejemplo fija.

- Al modelo solo se envían los mensajes que recibe el personaje del cliente activo. Una misma frase se traduce una sola vez y después se toma de la caché. No se envían los mensajes que solo contienen sistemas y naves. Si el idioma de destino es chino, japonés, coreano o ruso, tampoco se envían los mensajes que ya están en ese idioma. Si es inglés, alemán, francés o español, todos esos mensajes se envían al modelo, que decide si ya están en el idioma de destino. Los nombres de sistemas, regiones y naves usan su nombre oficial en el idioma de destino.
- Cada línea muestra la hora de EVE, el canal (solo si traduces más de uno), el remitente y la traducción. “Mostrar también el texto original” añade el original debajo; “Mostrar solo los mensajes traducidos” oculta los mensajes omitidos por estar ya en el idioma de destino, incluidos los que el modelo consideró escritos en él.
- Si el servicio rechaza la clave o se agota la cuota, la traducción se pausa y la línea de estado indica el motivo; “Reintentar ahora” lo intenta de nuevo.
- Las direcciones públicas deben usar `https`; `http` solo se acepta para este Mac o la red local, como Ollama en `http://127.0.0.1:11434/v1`.
- Las solicitudes usan tu cuenta en el servicio elegido y pueden costar dinero.
- Tras recompilar con otra firma, macOS puede pedir permiso para leer el elemento del llavero cuando haces clic en “Probar” o “Reintentar ahora”. Las lecturas en segundo plano están diseñadas para no mostrar esta petición; en su lugar, la línea de estado te pide que vuelvas a guardar la clave. Esto aún hay que comprobarlo a mano tras una recompilación real.

### Gestos de las superposiciones

Las superposiciones de inteligencia y de traducción son paneles separados que se comportan como las miniaturas: nunca toman el foco, aparecen en todos los Spaces y muestran solo el personaje de la ventana de EVE en primer plano, cambiando de contenido en cuanto cambias de cliente. Los clics no pasan al juego. El mensaje más reciente está abajo y la lista se queda ahí. Si te desplazas hacia arriba, la lista deja de seguir los mensajes nuevos y aparece abajo una barra “N nuevos”; haz clic en ella para volver a lo más reciente.

| Acción | Gesto |
| --- | --- |
| Desplazar la lista | Rueda del ratón o deslizar con dos dedos |
| Mover | Arrastrar con el botón derecho, u Opción + arrastrar con el botón izquierdo |
| Redimensionar | El mismo gesto que para mover, empezando a menos de 12 puntos del borde de la superposición |
| Desactivar temporalmente el ajuste | Mantén pulsada Mayúsculas al arrastrar |
| Abrir el menú | Clic derecho (moviendo menos de 4 puntos entre pulsar y soltar) |
| Volver a lo más reciente | Clic en la barra “N nuevos” |

El menú contextual ofrece Desplazar a lo más reciente, Copiar esta línea, Abrir en el navegador (solo en líneas con enlaces), Vaciar lista, Bloquear disposición, Restablecer posición y tamaño, Ocultar esta superposición y Abrir ajustes…. “Opacidad del fondo” (20 %–100 %, solo el fondo; el texto sigue opaco) y “Tamaño de letra” (10–24 puntos) están en la página de cada función. “Bloquear disposición” y “Ocultar las miniaturas si EVE no está en primer plano” también se aplican a las superposiciones; ocultar todas las miniaturas solo afecta a las miniaturas.

### Barra de menús

El icono de la barra de menús coincide con el icono de la app: una molécula dentro de un octógono. El menú ofrece: Mostrar u ocultar todas las miniaturas, cambiar de perfil, Minimizar todos los clientes, Atajos solo en EVE, Mostrar superposición de inteligencia, Mostrar superposición de traducción, Buscar actualizaciones…, Informar de un problema…, Ajustes y Salir. Cuando hay una actualización disponible o la ejecución anterior se cerró inesperadamente, aparece un punto en el icono y el menú muestra un ítem al respecto en la parte superior. Cuando falta un permiso, el menú tiene un ítem adicional sobre ello. Si detienes la captura de un cliente desde el indicador de grabación del sistema, el menú añade un ítem “Reanudar captura”.

EVE-O Preview también muestra su icono en el Dock; al hacer clic en él se abre la ventana de ajustes. Para dejar solo el icono de la barra de menús, desactiva “Mostrar icono en el Dock” en Ajustes > General.

### Actualizaciones

EVE-O Preview busca una nueva versión en GitHub al arrancar y una vez al día. Para desactivarlo, desmarca “Buscar actualizaciones automáticamente” en Ajustes > General > Actualizaciones; “Buscar actualizaciones…”, en el menú de la barra de menús, sigue buscando cuando lo pides.

Cuando hay una nueva versión disponible, una ventana muestra las notas de la versión en el idioma de tu interfaz (en inglés si no hay traducción) y ofrece Instalar actualización, Omitir esta versión y Más tarde. Mientras un cliente de EVE está en primer plano, la ventana espera hasta que cambies a otra app y nunca toma el foco del teclado por sí sola; un punto en el icono de la barra de menús indica que hay una actualización pendiente. “Omitir esta versión” solo detiene los recordatorios automáticos de esa versión; “Buscar actualizaciones…” la sigue mostrando.

Instalar actualización descarga el dmg, lo comprueba con `SHA256SUMS.txt`, verifica que la nueva app está firmada con el mismo certificado que la que está en ejecución, sustituye la app y la reinicia. Si falla algún paso, la app instalada no se modifica. “Instalar actualizaciones automáticamente” está activado por omisión: la actualización se descarga en segundo plano y después se instala y la app se reinicia cuando no se ha ejecutado ningún cliente de EVE durante aproximadamente un minuto y no hay ninguna ventana de EVE-O Preview abierta. Si no, se instala al salir de EVE-O Preview o al elegir “Reiniciar para actualizar a X.Y.Z” en el menú de la barra de menús. Mientras se ejecuta un cliente de EVE, la app nunca se reinicia por sí sola. Desactiva el ajuste en Ajustes > General > Actualizaciones si quieres que la ventana te pregunte antes.

Algunas compilaciones solo pueden mostrar el motivo y un botón “Abrir página de la versión” en lugar de instalar: las compilaciones ad hoc o firmadas localmente, una app que se ejecuta desde una imagen de disco o desde una ubicación trasladada (translocation), una app en una carpeta en la que no puedes escribir y una app en un volumen que no es APFS, como un disco externo HFS+, exFAT o FAT.

### Informar de un problema

Elige “Informar de un problema…” en el menú de la barra de menús o en la página General, o responde al aviso que aparece después de que EVE-O Preview se cierre inesperadamente. La ventana enumera todos los archivos que irán en el informe y muestra su contenido tras la anonimización: un resumen del entorno, un resumen de ajustes sin ningún nombre, el registro de la app (hasta 2 MiB) y hasta tres informes de fallo de macOS. No se crea nada hasta que haces clic en “Solo crear informe” o “Crear informe y abrir GitHub”. El zip se guarda en `~/Library/Application Support/EVE-O Preview/Reports/` (se conservan los 3 más recientes) y Finder lo muestra; “Crear informe y abrir GitHub” también abre un issue ya rellenado en tu navegador. Eres tú quien adjunta el zip; la app nunca sube nada.

Tu nombre de usuario de macOS, tu nombre completo, la ruta de tu carpeta de inicio y los nombres del ordenador se sustituyen por `[user]` y `[host]`. Los nombres de los personajes de EVE pasan a ser `[character-1]`, `[character-2]`, etc., y los identificadores del dispositivo de los informes de fallo pasan a ser `[redacted]`. Solo se sustituyen los nombres que la app conoce: los personajes que nunca aparecieron en tus ajustes ni como cliente en ejecución no se sustituyen. Si un nombre es una palabra común, también se sustituye esa misma palabra en otras partes del registro. Puedes leer todos los archivos antes de crear el informe y desmarcar cualquier archivo que no quieras incluir.

La app conserva hasta 5 archivos de registro de 1 MiB cada uno en `~/Library/Logs/EVE-O Preview/`. Los nombres de los personajes y los títulos de las ventanas se escriben como `<private>`. Activa “Registro detallado” en General para registrar también líneas de depuración; “Mostrar registros en Finder” abre la carpeta. Si no aparece ningún aviso tras un fallo, adjunta a mano `~/Library/Logs/DiagnosticReports/EVEOPreview-<date>.ips` al issue.

## Privacidad

La versión 1.0.0 no hacía ninguna solicitud de red. Desde la 1.1.0, la app se conecta a GitHub para las actualizaciones y no hace ninguna otra conexión salvo que actives alguna de las funciones opcionales descritas después de esta lista:

- La búsqueda de actualizaciones solicita `api.github.com/repos/deletexiumu/eve-o-preview-macos/releases/latest` al arrancar y una vez al día mientras “Buscar actualizaciones automáticamente” está activado, y cada vez que eliges “Buscar actualizaciones…”.
- Cuando se ofrece una versión nueva, la app también solicita una vez la lista de versiones `api.github.com/repos/deletexiumu/eve-o-preview-macos/releases`, con las mismas cabeceras, para mostrar las notas de las versiones que te saltaste.
- La instalación de una actualización descarga `SHA256SUMS.txt` y el dmg de la versión.

Las solicitudes solo llevan la versión de la app en la cabecera `User-Agent`, un `Accept-Language: en` fijo y una etiqueta de caché; no se envían nombres de personajes, ajustes, registros, datos del hardware, versión del sistema ni identificadores, y no se usan cookies. GitHub ve tu dirección IP y la hora de la solicitud. No hay telemetría ni envío automático de fallos: “Informar de un problema…” solo crea un zip en tu Mac y abre una página web que tú decides si enviar.

Las superposiciones de inteligencia y de traducción solo leen los registros de chat y del juego; nunca escriben en ellos, y las conversaciones privadas nunca se leen. Dos funciones opcionales se conectan a otros servicios:

- Comprobación de nombres de pilotos: “Comprobación de nombres en línea (ESI)” está activada por omisión en cuanto activas la superposición de inteligencia. Cuando un mensaje de inteligencia recibido por el personaje activo contiene nombres de pilotos de dos o más palabras seguidos, la app envía esas palabras, sueltas y en combinaciones de hasta tres, a la ESI de CCP en `esi.evetech.net/universe/ids`. No envía el remitente, el canal ni el resto del mensaje; los nombres de tus propios personajes solo se incluyen si alguien los escribió en un mensaje de inteligencia. Un nombre que aparece solo y tiene una sola palabra nunca se consulta. CCP ve tu dirección IP y la cabecera `User-Agent`, que contiene la versión de la app y la URL del proyecto. Desactiva el ajuste en la página Inteligencia para detener estas solicitudes. La app nunca se conecta por sí misma a zKillboard: “Abrir en el navegador” abre la página de zKillboard de un personaje en tu navegador, con solo el ID del personaje en la dirección.
- Traducción del chat (desactivada por omisión): el texto de los mensajes que recibe el personaje del cliente activo en tus canales de traducción se envía al servicio de modelos elegido en la página Traducción, junto con los nombres oficiales de los sistemas y naves que mencionan. No se envían los nombres de remitentes ni de canales; “Probar” envía una frase de ejemplo fija. La clave de API se guarda solo en el llavero de macOS, con el servicio `io.github.deletexiumu.eveopreview-macos.translation` y un elemento por servicio de modelos, y solo se envía a ese servicio. Nunca aparece en el archivo de configuración, los registros ni los informes de problemas. Las direcciones públicas deben usar `https`; `http` solo se acepta para este Mac o la red local, por ejemplo Ollama. Lo que el servicio haga con el texto se rige por sus propias condiciones.

Los informes de problemas contienen los ajustes de estas funciones como números e interruptores (como el número de canales y el servicio elegido), pero no nombres de canales ni de sistemas, direcciones de API, nombres de modelos, nombres de pilotos, texto del chat ni claves.

La app guarda datos en estos lugares. Para desinstalarla por completo, elimínalos junto con la app y `~/Library/Application Support/EVE-O Preview/config.json`:

| Ubicación | Contenido |
| --- | --- |
| `~/Library/Logs/EVE-O Preview/` | Registros de la app, unos 5 MiB como máximo |
| `~/Library/Application Support/EVE-O Preview/session.json`, `state.json` | Marcador de sesión; registros de actualizaciones y diagnóstico; ubicaciones manuales de inteligencia |
| `~/Library/Application Support/EVE-O Preview/Reports/` | Los zips de informes de problemas que has creado, anonimizados (los 3 más recientes) |
| `~/Library/Caches/io.github.deletexiumu.eveopreview-macos/Updates/` | Archivos de actualización descargados, que se eliminan tras la instalación |
| `~/Library/Application Support/EVE-O Preview/pilot-names.json` | Nombres de pilotos e ID de personajes encontrados por la ESI (datos públicos del juego), guardados durante 30 días. Solo tú puedes leerlo (0600) y nunca se incluye en los informes de problemas; “Vaciar caché de nombres” en la página Inteligencia lo vacía. Los nombres sin coincidencia solo se guardan en memoria durante 6 horas |
| `~/Library/Application Support/EVE-O Preview/translation-cache.json` | Texto original y traducido de los mensajes, sin nombres de remitentes ni de canales. Solo tú puedes leerlo (0600) y nunca se incluye en los informes de problemas; “Vaciar caché” en la página Traducción lo vacía |
| Elementos del llavero con el servicio `io.github.deletexiumu.eveopreview-macos.translation` | Tus claves de API de traducción, una por servicio de modelos; “Eliminar clave” en la página Traducción borra la del servicio actual |

## Archivo de configuración

La configuración se guarda en `~/Library/Application Support/EVE-O Preview/config.json`. Un solo archivo contiene todos los perfiles.

- Los cambios se guardan automáticamente 0,5 segundos después de hacerlos, y una vez más al salir.
- Si el archivo está dañado, se renombra a `config.corrupt-<date-time>.json` y la app usa la configuración predeterminada.
- Si el archivo procede de una versión más reciente, la app se ejecuta con la configuración predeterminada, no escribe en el disco durante esa sesión y no sobrescribe el archivo.

La página Perfiles tiene un botón “Mostrar en Finder”.

## Desarrollo

| Comando | Función |
| --- | --- |
| `swift build` | Compilar todos los targets |
| `swift test` | Ejecutar las pruebas unitarias de Core (swift-testing) |
| `EVEO_FAKE=1 swift run EVEOPreview` | Modo de demostración: 3 clientes ficticios con imágenes animadas generadas, sin necesidad de EVE ni de ningún permiso |
| `python3 scripts/check_quality.py` | Comprobar la proporción de comentarios, la longitud de los archivos y la de las funciones |
| `scripts/build-app.sh` | Ensamblar y firmar la `.app` |
| `scripts/package-release.sh` | Generar el dmg, los archivos de código fuente y las sumas de comprobación en `dist/release/` |
| `swift run EVEOProbe gamelog [dir] [--follow seconds]` | Contar cada tipo de línea de combate en los registros del juego, para diagnosticar las alertas de combate |
| `swift run EVEOProbe mousetap <seconds> [--swallow <button>]` | Mostrar los números de los botones del ratón, para diagnosticar los atajos del ratón |
| `swift run EVEOProbe update feed [url]` | Descargar y analizar el feed de versiones |
| `swift run EVEOProbe update verify <new app> <base app>` | Comprobar si una nueva app cumple el designated requirement de la app base |
| `swift run EVEOProbe update prepare <url> [--cache dir]` | Descargar y verificar una actualización sin instalarla |
| `scripts/make-update-test-feed.sh [version]` | Escribir un `feed.json` para una prueba local de actualización a partir de `dist/release/` |
| `swift run EVEOProbe staticdata` | Mostrar dónde se encontró el archivo de datos del mapa, su versión del SDE, el número de registros y el tiempo de una tabla de distancias de 15 saltos |
| `swift run EVEOProbe chatlog [dir] [--follow seconds]` | Mostrar la carpeta de registros de chat, los tipos de canal y el número de mensajes y líneas de ubicación, sin nombres ni texto de los mensajes |
| `swift run EVEOProbe intel [dir] [--resolve-sample] [--resolve]` | Contar mensajes de inteligencia, sistemas, naves y nombres de pilotos en los registros de chat recientes; `--resolve-sample` envía tres nombres inventados a la ESI y `--resolve` envía a la ESI los nombres de pilotos de tus registros |
| `swift run EVEOProbe translate [--provider id] [--model name] [--base-url url] [--target language] [--dry-run]` | Enviar un ejemplo fijo a un servicio de modelos, con la clave tomada solo de `EVEO_TRANSLATION_API_KEY`. Sin `--dry-run` es una solicitud real que puede costar dinero |
| `python3 scripts/build-sde-data.py [--check]` | Descargar el SDE de CCP y regenerar `packaging/eve-static.json`; `--check` solo compara la versión del SDE |

El modo de demostración escribe su configuración en `config-fake.json` en la misma carpeta, sin tocar la configuración real. También ofrece dos canales de chat ficticios, `intel.Demo` y `chat.Demo`, traduce con un servicio ficticio que antepone 〔译〕 a cada línea y comprueba los nombres de pilotos sin conexión de red. Estas variables de entorno ayudan a depurar:

| Variable | Función |
| --- | --- |
| `EVEO_CONFIG_PATH` | Usar el archivo de configuración indicado |
| `EVEO_LANG` | `en`, `zh`, `ru`, `ja`, `ko`, `fr`, `de` o `es`; anula el idioma de la interfaz de la configuración |
| `EVEO_FAKE_DENY` | En el modo de demostración, simular que falta un permiso: `screen`, `ax` o `screen,ax` |
| `EVEO_FAKE_STOP_AFTER` | En el modo de demostración, simular que el usuario detuvo la captura del segundo cliente tras este número de segundos |
| `EVEO_SETTINGS_PAGE` | Abrir directamente una página de ajustes al arrancar, como `previews` |
| `EVEO_LOG_DIR` | Escribir los archivos de registro en otra carpeta (por omisión `~/Library/Logs/EVE-O Preview/`) |
| `EVEO_STATE_DIR` | Guardar `state.json` y `session.json` en otra carpeta |
| `EVEO_LOG_PRIVATE` | `1` muestra los valores privados solo en el registro del sistema (Consola); los archivos de registro siempre contienen `<private>` |
| `EVEO_UPDATE_FEED_URL` | Buscar actualizaciones en esta dirección en lugar de GitHub; solo `https` o `http` en un host de loopback. Las compilaciones firmadas con un certificado local pueden instalar desde ella; la comprobación de la firma no se relaja |
| `EVEO_UPDATE_UI_STATE` | En el modo de demostración, mostrar la interfaz de actualización en un estado de ejemplo: `available`, `notifyonly`, `downloading`, `ready`, `failed` o `uptodate` |
| `EVEO_FAKE_CRASH` | `1` en el modo de demostración simula que la ejecución anterior falló, para mostrar el aviso del informe de fallo |
| `EVEO_STATIC_DATA` | Usar este archivo de datos del mapa en lugar del incluido en la app |
| `EVEO_TRANSLATION_API_KEY` | Clave de API solo para `EVEOProbe translate`; la app nunca la lee |

Los datos del mapa y de las naves que usan las superposiciones de inteligencia y de traducción (sistemas, regiones, portales estelares, grupos de naves y naves, con sus nombres en los 8 idiomas de la interfaz) se generan a partir de la exportación de datos estáticos de CCP (SDE) con `scripts/build-sde-data.py` y se incluyen en la app como `packaging/eve-static.json`; `scripts/build-app.sh` copia el archivo en la app. La app no descarga estos datos durante la ejecución. Para probar un archivo más reciente sin recompilar, colócalo en `~/Library/Application Support/EVE-O Preview/eve-static.json`.

El código fuente tiene 3 módulos: `EVEOPreviewCore` es la capa de lógica pura, `EVEOPreviewPlatform` envuelve AppKit, ScreenCaptureKit, Accesibilidad y los atajos de Carbon, y `EVEOPreview` es la propia app. La arquitectura se describe en [docs/architecture.md](docs/architecture.md) (en chino).

**Nota:** cuando ejecutas el ejecutable directamente con `swift run`, macOS registra los permisos a nombre de tu app de terminal, no de `EVE-O Preview.app`.

### CI y versiones

`.github/workflows/build.yml` se ejecuta en runners de macOS alojados por GitHub:

- Cada pull request a `main`, y cada push a `main`, ejecuta el control de calidad y las pruebas unitarias, y después genera un dmg universal y los archivos de código fuente. Se suben como un artefacto del workflow llamado `EVE-O-Preview-<version>-pr.<number>.<commit>` (o `-dev.<commit>` para los push) y se conservan 30 días.
- Al hacer push de una etiqueta `v*` se generan los mismos archivos y se publican como una GitHub Release. La etiqueta debe coincidir con el archivo `VERSION`. Si existe `docs/release-notes/<tag>.md`, se convierte en las notas de la versión.

Para publicar una nueva versión, cambia el archivo `VERSION` y añade `docs/release-notes/v<version>.md` en un pull request, fusiónalo y después etiqueta `main`: `git tag v<version> && git push origin v<version>`.

Los nombres de los archivos (`EVE-O-Preview-<version>.dmg`, `SHA256SUMS.txt`), la estructura del dmg, el certificado de firma y el formato de las notas de la versión son un contrato con el actualizador integrado en la app; la CI los comprueba en cada compilación. Las notas de la versión ponen primero el inglés entre `<!-- lang:en -->` y `<!-- /lang:en -->`, seguido de bloques plegables zh, ja, ko y ru marcados del mismo modo; `scripts/check_release_notes.py` comprueba los marcadores. Los detalles están en las secciones 9.5 a 9.7 de [docs/architecture.md](docs/architecture.md).

## Aviso legal

Esta herramienta solo cambia el foco de las ventanas. No reenvía la entrada a varios clientes y no lee ni modifica la memoria del juego, el mismo límite que el proyecto original. Las superposiciones de inteligencia y de traducción solo leen los archivos de registro que escribe el cliente. Lee el Acuerdo de Licencia de Usuario Final de EVE Online antes de usarla.

La app se conecta a GitHub para buscar y descargar actualizaciones. Solo se conecta a la ESI de CCP y a un servicio de traducción si activas esas funciones opcionales, y solo envía lo que describe [Privacidad](#privacidad).

EVE Online y los logotipos relacionados son marcas comerciales de CCP ehf. Este proyecto no está afiliado a CCP ni cuenta con su respaldo.

El icono de la app reutiliza el icono de la molécula del proyecto original EveOPlus/eve-o-preview (GPL-3.0). El fondo lo dibuja `scripts/make-app-icon.py` y no contiene marcas comerciales de CCP ni arte del juego.
