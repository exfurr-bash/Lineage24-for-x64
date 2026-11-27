# XMLs Vulkan

Os arquivos desta pasta são cópias dos XMLs de permissões do Android Open
Source Project (AOSP), mantidos em platform/frameworks/native/data/etc.
Cada arquivo inclui o aviso de copyright e a licença Apache-2.0 do próprio
AOSP. Eles não passam a ser GPL-2.0-only por estarem neste repositório.

| Arquivo neste repositório | Fonte AOSP |
| --- | --- |
| android.hardware.vulkan.compute-0.prebuilt.xml | android.hardware.vulkan.compute-0.xml |
| android.hardware.vulkan.level-1.prebuilt.xml | android.hardware.vulkan.level-1.xml |
| android.hardware.vulkan.version-1_3.prebuilt.xml | android.hardware.vulkan.version-1_3.xml |
| android.software.opengles.deqp.level-latest.prebuilt.xml | android.software.opengles.deqp.level-latest.xml |
| android.software.vulkan.deqp.level-latest.prebuilt.xml | android.software.vulkan.deqp.level-latest.xml |

O Android.bp do AOSP mapeia os nomes prebuilt aos XMLs de origem. Consulte a
[árvore AOSP frameworks/native/data/etc](https://android.googlesource.com/platform/frameworks/native/+/refs/tags/android-security-17.0.0_r2/data/etc)
e a licença Apache-2.0 em [LICENSE](https://www.apache.org/licenses/LICENSE-2.0).
Os SHA-256 das cópias presentes aqui estão em config/sources.lock.
