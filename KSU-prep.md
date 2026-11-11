# Preparação: KernelSU no Generic x86_64 (LineageOS 24.0, kernel 7.2.0+)

> **Estado: KSU NO AR ✅ (2026-11-10, artefatos v4, Rota A builtin)** — boot real
> confirmado pelo usuário na entrada GRUB `LineageOS 24.0 (KSU, persistent
> data)`. Três bugs de kernel/build corrigidos em sequência (boots 1–3:
> #CP no initcall, BTF de módulo divergente, `EXT4_FS_SECURITY` derrubada por
> bug de regex) e revalidados por matriz QEMU (T-A/T-B/T-D/T-E) antes de
> cada retest. Entrada stock intocada; rollback completo em
> `backup-p7-20261109/` (kernel, ramdisk, grub.cfg, sha256sums).
> **Fase 2 (nova): aceleração gráfica** — Android usa só OpenGL ES, sem
> Vulkan (ver seção "Fase 2" no fim).

## Kernel panic no 1º boot KSU: causa raiz, diagnóstico e fixes (2026-11-09)

### Sintoma
Panic @ 10,6 s, **dentro do initcall do KernelSU** — PID 1 morre com SIGSEGV:
`kernelsu_init → ksu_syscall_hook_init → ksu_resolve_symbol_for_functable_hook
(call @+0x69, ret @+0x6f) → asm_exc_control_protection (#CP)` e o oops-2
termina no `ud2` de `do_kernel_cp_fault+0x111` (dois `#CP` em kernel-mode sem
handler tolerável). "Attempted to kill init! exitcode=0x0b".

### Evidências-chave (logs do boot + desassembly do artefato)
- `CR4=0x00f70ef0` → **bit 23 CET=0: a IBT NÃO estava ativa no hardware** no
  crash. A teoria «chamada indireta caiu fora do landing pad IBT» não se
  sustenta sozinha — um #CP não deveria existir com CET desligado. A pista
  real está no valor de R11 (abaixo): o endereço chamado era inválido.
- `R11 = ffffd0f9c13de800` — endereço em região **vmalloc/stack** (adjacente à
  stack de init `0xffffd0f9c0103xxx`), **NÃO** é texto do kernel.
  Runtime esperado do callback: `find_kernel_symbol_exact_cb =
  ffffffff820e61d0 + KASLR 0x15800000 = ffffffff978e61d0`.
- `Code: Unable to access opcode bytes at 0xffffffff978e60d6` → link
  `ffffffff820e60d6` (gaps ~0xEA/~0x12A dos símbolos próximos, página não
  mapeada): a execução abortou ao tentar ler bytes ~0xEA abaixo do callback
  esperado (`…61d0`) — região não mapeada, coerente com endereço inválido.
- A chamada indireta não é `call *%r11` direto: compila para o thunk
  retpoline `__pi___x86_indirect_thunk_r11` (`call +1; mov %r11,(%rsp);
  jmp __pi___x86_return_thunk`) — o despacho final acontece via `ret`, a
  partir de R11.
- Com `X86_FEATURE_IBT` ausente (CR4.CET=0), `do_kernel_cp_fault` não tem o
  ramo de "WARN + return" e cai no BUG final (`ud2` em `+0x111`) — por isso o
  duplo oops em vez de um aviso recuperável.

### Causa raiz (fechamento do diagnóstico)
O KSU resolve `kallsyms_on_each_match_symbol` em runtime (via
`kallsyms_lookup_name`/`kallsyms_lookup` em `ksu_init_symbol_resolver()`),
guarda o endereço na global `kallsyms_on_each_match_symbol_fn` e chama por
ela indiretamente. No crash essa global continha `ffffd0f9c13de800`
(vmalloc) em vez do runtime correto `ffffffff978e61d0` — uma chamada
indireta para esse endereço aborta sempre, com ou sem IBT.

Teorias descartadas com dados do artefato IBT=y:
- `altinstructions` (13.257 entradas): 0 hits perto de
  `kallsyms_on_each_match_symbol` (@ffffffff8143dfd0) → não era alt-patch;
- o landing pad `endbr64` está presente no corpo estático da função no
  vmlinux → o "endbr sealing" do objtool não removeu o corpo no estático;
- `mitigations=off` na cmdline → despacho via retpoline (`ret`), sem
  check de IBT no despacho.

Ponto estrutural: **chamada indireta sobre endereços vindos de kallsyms em
runtime é frágil**. O valor inválido exato na global segue em aberto
(hipótese principal: erro de resolução no caminho de init em interação com
KASLR/MODVERSIONS — fica p/ report upstream, não bloqueia o retest). O
conserto elimina a indireção no modo builtin e tira a IBT do build,
protegendo contra a classe inteira de falha.

### Os 2 fixes aplicados (defesa em camadas)
1. **`CONFIG_X86_KERNEL_IBT=n`** no build (`build_kernel_ksu.sh`,
   CONFIG_APPEND + guard pós-olddefconfig que aborta se voltar a `y`).
2. **Patch local em `KernelSU/kernel/infra/symbol_resolver.c`** (não
   commitado no tree KSU v3.3.1 — candidatado a report upstream): quando
   builtin (`IS_BUILTIN(CONFIG_KSU)`) define `KSU_DIRECT_KALLSYMS=1`,
   remove a global fn-pointer e chama
   `kallsyms_on_each_match_symbol(...)` **diretamente** (chamada direta não
   depende de endereço resolvido em runtime nem de indireção passível de
   sealing IBT). Em modo módulo, o caminho antigo (ponteiro + resolução na
   init) fica intacto. Detalhes: define fora do guard
   `HAVE_ON_EACH_MATCH_SYMBOL` (evita macro indefinida em kernels <6.1),
   declaração condicional da global, call direta em
   `find_kernel_symbol_exact()` e `ksu_init_symbol_resolver()` só resolve
   ponteiros quando `!KSU_DIRECT_KALLSYMS`.

### Rebuild & aplicação (artefatos v2)
- bzImage versionado `#6` (o que panicou era o `#4`; o `#5` foi
  intermediário, nunca aplicado).
- **`Module.symvers` byte-idêntico** ao build anterior (IBT=y; backup em
  `/tmp/opencode/Module.symvers.ibt-y.bak`) → CRCs MODVERSIONS inalterados →
  **módulos NÃO rebuildados**; `modstaging` reutilizado no repack.
- Config embutido verificado no `kernel.ksu` instalado (extract-ikconfig):
  `CONFIG_KSU=y`, `CONFIG_KSU_X86_PATCH_SYSCALL_DISPATCHER=y`,
  `CONFIG_EXT4_FS=y`, `CONFIG_MODULES=y`,
  `# CONFIG_X86_KERNEL_IBT is not set`.
- sha256 `kernel.ksu` == build bzImage:
  `9444d4f979b72b424e5feb284db37261d0220a246231fdf44f3f322a401626f9`.
- vendor_dlkm: 3973 .ko; ramdisk: 653 .ko substituídos, 4 builtin removidos
  (crc16, ext4, jbd2, mbcache), 3 trailers, sanity OK.
- GRUB linha 31 → `kernel.ksu` + `androidboot.android_dir=…-ksu`, linha 33
  initrd `.ksu`; stock linhas 21/42/53/64 intocadas.
- p7 remontada (`sudo mount /dev/nvme0n1p7 /mnt/p7`) — tinha sido desmontada
  no reboot do host.

### Se falhar de novo no mesmo lugar
- salvar o oops novo (transcrição da tela) — comparar `R11`/`RAX`/`Code:` do
  #CP;
- se o endereço de falha mudar para texto de kernel válido e ainda der
  `#CP`, conferir se o patch pegou: `nm vmlinux | grep resolve_symbol` e
  desassemblar `ksu_resolve_symbol_for_functable_hook` (não pode haver
  despacho pela global em `+0x69`).

## Boot 2 KSU: "Missing block device for android dir" — causa raiz (BTF de módulo) e fix (2026-11-10)

### Sintoma
- O #CP sumiu (fix v2 funcionou: kernel passou do initcall), mas o boot parou
  mais adiante: `generic_init` entra em loop
  `CanQuitUeventd: Missing block device for android dir` a cada 5 s.
- NVMe é módulo (`NVME_CORE=m`, `BLK_DEV_NVME=m`); sem uevents do nvme,
  nenhum block device é escaneado → o loop é o sintoma, não a doença.

### Diagnóstico: repro completa no QEMU (~3 min, sem tocar na máquina)
- Comando: `qemu-system-x86_64 -enable-kvm -machine q35 -cpu host -m 3072
  -kernel …/kernel.ksu -initrd …/ramdisk-all-combined.ksu.img -append "<cmdline
  da linha 31 + console=ttyS0>" -drive
  file=/dev/nvme0n1p7,format=raw,if=none,id=p7,readonly=on,cache=none -device
  nvme,drive=p7,serial=P7DISK -nographic -monitor none -no-reboot` (com
  `sudo`, KVM precisa de acesso ao disco). Log completo do boot em ttyS0.
- Resultado: **todos os insmod falham com EINVAL** e o log do kernel mostra o
  motivo logo antes de cada falha:
  `BPF: [162669] Invalid name_offset:2653910` / `BPF: Invalid name` /
  `failed to validate module [nls_utf8] BTF: -22`.
- O kernel não loga mais nada sobre o módulo (nem "Invalid module format");
  o "Failed to insmod … Invalid argument" é do `generic_init` (userspace).

### Mecanismo (código do kernel, `kernel/bpf/btf.c`)
- No `MODULE_STATE_COMING`, `btf_module_notify` chama `btf_parse_module`:
  se a validação do split-BTF do módulo falha, `pr_warn("failed to validate
  module [%s] BTF: %ld")` e o módulo **não carrega** (notifier retorna erro →
  EINVAL no finit_module).
- Exceção: `CONFIG_MODULE_ALLOW_BTF_MISMATCH=y` degrada a falha para
  `pr_warn_once("Kernel module BTF mismatch detected…")` e o módulo carrega
  **sem** BTF. (Depende de `DEBUG_INFO_BTF_MODULES`; no tree, ambas em
  `lib/Kconfig.debug`.)
- Evidência de que o validador é fatal no nosso kernel: no teste T2 abaixo,
  até `.ko` **stock** falham com BTF -22 no kernel KSU.

### Testes cruzados QEMU (isolaram o culpado)
| Teste | Kernel | Módulos | Resultado |
|---|---|---|---|
| T1 | stock | nossos (modstaging) | 55 falhas, todas `BTF: -22` |
| T2 | KSU (v2) | stock (backup) | 40 carregam, 16 falham `BTF: -22` |
- T1: nossos `.ko` falham **inclusive no kernel stock** → o BTF gerado pelo
  nosso build (pahole v1.32 da distro + clang 23) é inválido por si.
- T2: o kernel KSU **carrega módulos normais**; os que falham são módulos
  stock cujo split-BTF referencia o vmlinux **stock** — e o vmlinux do nosso
  rebuild tem BTF diferente (config mudou) → mismatch fatal.
- Conclusão: `.BTF` de módulo só valida se o vmlinux do kernel **for o mesmo
  do build de origem dos módulos**. Qualquer troca de kernel/config sem
  rebuild completo dos módulos quebra.

### Fix aplicado (artefatos v3, 2026-11-10 20:55)
- Strip de `.BTF`/`.BTF.ext` nos **3973** `.ko` do modstaging:
  `find … -name "*.ko" -print0 | xargs -0 -P4 -n1 objcopy --remove-section=.BTF
  --remove-section=.BTF.ext` (**`-n1` obrigatório**: objcopy aceita 1 arquivo
  por invocação — `-n50` falha silenciosa e não altera nada).
- Sem BTF, `mod->btf_data_size == 0` → validação nem roda → módulo carrega.
  CRCs MODVERSIONS (`__versions`) e vermagic intactos → sem rebuild de
  kernel/módulos. Restaram 4 `.ko` com match em `\.BTF` — só seção
  `.BTF_ids` (legítima, não é BTF).
- `install_kernel_ksu.sh --apply-boot` re-executado: `kernel.ksu` inalterado
  (sha256 v2), `ramdisk-all-combined.ksu.img` 83,4 MB (653 substituídos, 4
  builtin removidos, sanity OK), `vendor_dlkm.ksu.img` 185 MB regenerado
  (hardlink `↔vendor_dlkm.img`), GRUB "já existe".

### Sanity QEMU pós-fix (v3): VERDE (2026-11-10)
- Run 1 (`readonly=on`): **52 módulos carregam** (antes: 40 com tudo BTF-reprovado),
  **zero erros BTF**; único insmod que falha é `nls_euc-jp` com EINVAL
  silencioso — **preexistente**: falha igual em stock×stock no QEMU (quirk
  inofensivo, 1 de 653, codepage). nvme probe ok
  (`nvme0: pci function 0000:00:03.0`), mas o mount da p7 falha com I/O error
  **porque a imagem está readonly no QEMU** e o ext4 exige journal recovery
  (escrita) antes de montar RO → não é problema real.
- Run 2 (`-snapshot`: overlay temporário, p7 intocada): fluxo completo verde —
  `EXT4 recovery complete` → **`Block device /dev/block/nvme0n1 have android
  directory: android-Generic_x86_64-ksu`** → **0 ocorrências de "Missing
  block device"** → ueventd sai do loop → switch root → **todas as imgs
  montam** (loop0–4: system, firmware, vendor, system_dlkm, **vendor_dlkm.ksu
  repacotado**) → módulos de `/vendor_dlkm/lib/modules` carregam → **KSU
  inicializa por completo** (dispatcher slot 134, hooks 59/117/262/269/322,
  su_compat, sepolicy backup, `/system/bin/init second_stage executed`).
- O boot termina em QEMU com `bootstrap-apexd-failed` (~14 s) — **NÃO era
  artefato do ambiente**: era a causa raiz do **Boot 3** (capítulo abaixo).
  O cross-test stock da época usava cmdline de fidelidade parcial e por isso
  não era comparável; com cmdline de fidelidade total, o cross-test
  **T-D (stock×stock + dir `-ksu`)** **PASSA** (`apexd-bootstrap: Activated
  10 packages. duration=34ms`) — repack do `vendor_dlkm` e dir `-ksu` são
  **inocentes**; o culpado era o kernel (v3) por si só.
- Bônus do cross-test stock: os `.ko` stripados (do `vendor_dlkm.ksu.img` e do
  ramdisk KSU) carregam **no kernel stock** sem nenhum erro BTF → o strip é
  portável; falhas restantes são as de sempre (snd-pcsp EBUSY, drm ENOENT,
  intel-cstate ENODEV — benignas, iguais no boot stock).
- Logs: `/tmp/opencode/q-sanity3.log` (ro), `/tmp/opencode/q-sanity4.log`
  (snapshot), `/tmp/opencode/q-sanity4-stock.log` (stock×stock).

### Prevenção no build (build_kernel_ksu.sh)
- `CONFIG_MODULE_ALLOW_BTF_MISMATCH=y` no `CONFIG_APPEND` + guarda
  pós-olddefconfig: qualquer BTF divergente/inválido passa a ser só aviso.
- Alternativa exclusiva: `CONFIG_DEBUG_INFO_BTF_MODULES=n` (módulos do tree
  nascem sem `.BTF`; não cobre `.ko` prebuilt). Escolhemos a primeira por
  cobrir ambos os casos.

### Nota Rota B (LKM, só se algum dia for pedido)
- Um `.ko` KSU compilado por nós contra o kernel **stock** também teria BTF
  gerado pelo nosso pahole (possivelmente inválido) e/ou divergente do
  vmlinux stock → precisaria do mesmo strip de `.BTF`, senão o insmod falha
  com EINVAL no kernel stock (que não tem `ALLOW_BTF_MISMATCH`).

## Boot 3 KSU: `bootstrap-apexd-failed` — causa raiz (`EXT4_FS_SECURITY` derrubada por bug do sed) e fix (2026-11-10)

### Sintoma
- **Real**: boot KSU passa do block device e desliga sem salvar log (morreu
  antes do ponto de save do `save_early_logs=1`). Diagnóstico sem log: o
  próprio boot grava o motivo em `metadata/bootstat/persist.sys.boot.reason`
  → `bootloader,bootstrap-apexd-failed` (mtime 21:09 = hora do boot KSU).
- **QEMU (v3, `-snapshot`)**: `apexd-bootstrap: Mounting failed for package
  /system/apex/com.android.runtime.apex: Operation not supported on transport
  endpoint` (EOPNOTSUPP, errno 95) em todos os payloads bootstrap →
  `init: Got shutdown_command 'reboot,bootloader,bootstrap-apexd-failed'`
  ~7,4 s. Mesmo ponto do real.

### O que NÃO era (cada um eliminado por evidência)
- Avisos de loop do apexd (`Failed to create a new loop device … 0:38`,
  `Failed to convert 0:38to block device name`): **ruído de todo boot** —
  presentes em TODOS os boots stock reais que passam (early_logcat.log
  acumulado em `metadata/`, boots 11-08+); `LOOP_CTL_GET_FREE` devolve
  **índice**, o apexd o interpreta como dev_t e a leitura de
  `/sys/dev/block/0:38` falha — inofensivo. (`Fallback to buffered I/O` segue.)
- `Failed to load kernel modules from ramdisk` (só `nls_euc-jp`, EINVAL):
  quirk preexistente (falha igual em stock×stock).
- **Repack do `vendor_dlkm` / dir `-ksu`: inocentes** — ver T-D abaixo. A
  hipótese de "segundo fator" do dia 10 à noite nasceu de um teste com cmdline
  de fidelidade parcial (sem `androidboot.init_fatal_reboot_target=recovery`
  e `binder.impl=rust`) e se desfez ao repetir com fidelidade total.
- Módulos rejeitados no T-B (`failed to validate module [rfkill|parport|…]
  BTF: -22` — 41 módulos do vendor_dlkm STOCK): artefato da célula T-B
  (módulos stock em kernel nosso com `ALLOW_BTF_MISMATCH=n`); no caminho real
  todos os módulos são nossos (CRC/BTF coerentes) e não influem no
  apexd-bootstrap.

### Matriz QEMU decisiva (cmdline = linha 31 do GRUB na íntegra, só
`console=tty0`→`ttyS0`; `-snapshot`; disco p7 como NVMe `serial=P7DISK`)

| Célula | Kernel | Ramdisk | android_dir | apexd-bootstrap |
|---|---|---|---|---|
| T-A | stock | stock | original | ✅ `Activated 10 packages. duration=36ms` |
| T-B | KSU v3 | KSU v3 | original | ❌ EOPNOTSUPP → reboot bootstrap |
| T-D | stock | stock | `-ksu` (repack nosso) | ✅ `Activated 10 packages. duration=34ms` |

→ culpado **único**: o kernel KSU v3. Logs: `/tmp/opencode/q-TA.log`,
`q-TB.log`, `q-TD.log` (voláteis — /tmp é limpo no reboot do host).

### Mecanismo (corrente fechada em código)
1. `diff` das configs embutidas (extract-ikconfig, stock × nosso):
   `EXT4_FS_POSIX_ACL` e `EXT4_FS_SECURITY` viraram `not set` — efeito
   colateral **não intencional** do delta `EXT4_FS=m→y`.
2. **Bug no `build_kernel_ksu.sh`**: o loop do CONFIG_APPEND removia com
   `sed -i "/^${key}/d"` — para `key=CONFIG_EXT4_FS`, o padrão sem boundary
   apagava **todas** as linhas `CONFIG_EXT4_FS_*` (`_SECURITY`, `_POSIX_ACL`,
   …). O `olddefconfig` então aplicava os **defaults**: as opções sem
   `default y` (SECURITY, POSIX_ACL) viraram `n`; as com `default y`
   (`EXT4_USE_FOR_EXT2`) sobreviveram — exatamente o padrão visto no diff.
3. Kernel (`security/selinux/hooks.c`, `sb_check_xattr_support()`): ext4 sem
   handler de xattr de segurança → `__vfs_getxattr(root, XATTR_NAME_SELINUX)`
   retorna `-EOPNOTSUPP` → `pr_warn("SELinux: (dev …, type ext4) has no
   security xattr handler")` → fallback genfs
   (`security_genfs_sid("ext4", "/", …)`) que **falha** (política SELinux
   ainda não carregada no bootstrap; sem entrada genfs para ext4) →
   `return -EOPNOTSUPP`.
4. O `mount(2)` inteiro falha com EOPNOTSUPP **mesmo** com o ext4 já tendo
   logado "mounted filesystem" no dmesg (o superblock é criado e descartado —
   por isso o par mounted/unmounted aparece no log do T-B).
5. `apexd.cpp:592` (`platform/system/apex @ lineage-24.0`):
   `mount(...) != 0` → `ErrnoError() << "Mounting failed for package "` →
   qualquer payload ext4 falha → bootstrap falha → shutdown
   `reboot,bootloader,bootstrap-apexd-failed`.
6. Evidência numérica: mensagem SELinux = **0** ocorrências no T-A, **10** no
   T-B, **0** em todos os boots stock reais salvos. O payload erofs (loop7)
   monta bem (nosso `EROFS_FS_SECURITY=y` — igual ao stock).

### Fix (artefatos v4)
- `build_kernel_ksu.sh`:
  - sed do append com **match exato**: `/^${key}=/d;/^# ${key#CONFIG_} is not
    set$/d` (não mais o prefixo sem boundary);
  - `CONFIG_APPEND` agora contém **só linhas `CONFIG_*`** — os comentários
    narrativos saíram da string (aspas `"` e `/` dentro dela quebravam o parse
    do bash e o sed; o script com aqueles comentários **nunca tinha sido
    executado** — `bash -n` passa porque as aspas se equilibram com as de
    baixo; sintoma: exit 127 "comando não encontrado" na linha do comentário);
  - loop pula linhas `#*` (defesa extra);
  - `EXT4_FS_SECURITY=y` e `EXT4_FS_POSIX_ACL=y` restaurados explicitamente no
    append **e** com guardas pós-olddefconfig (die se sumirem).
- Rebuild do bzImage (v4); artefatos regerados com
  `install_kernel_ksu.sh --apply-boot` (idempotente; atualiza o hardlink
  `vendor_dlkm.img` do dir `-ksu` e mantém a entrada GRUB).

### Sanity QEMU pós-fix (v4): VERDE (2026-11-10 ~22:55)
- **T-E (KSU×KSU + dir `-ksu`, célula idêntica ao boot real)**:
  **`apexd-bootstrap: Activated 10 packages. duration=41ms`** ✅ —
  **0** `Mounting failed`, **0** `security xattr handler`, **0** rejeições
  BTF, **0** CRC mismatch.
- O boot seguiu **muito além do bootstrap** (o timeout de 110 s encerrou o
  QEMU, sem reboot): `init second_stage`, parsing de zygote rc,
  servicemanager, HALs (~99 s) — mesma classe do T-A stock (que também só
  termina por timeout). No v3 a morte era ~7,4 s.
- KSU 100%: `KernelSU: welcome to KernelSU version 32680` (v3.3.1),
  `x64_sys_call` patchado (dispatcher slot 134), `/system/bin/init second
  stage executed`, zygote SID cacheado.
- Artefatos v4 aplicados em p7: `kernel.ksu` (sha256
  `158194a7139b5e6f…`, 14,5 MB), `ramdisk-all-combined.ksu.img` (83,3 MB;
  653 módulos trocados, 4 builtin removidos, round-trip byte-idêntico),
  `vendor_dlkm.ksu.img` (184 MB; 3973 `.ko`; strip de `.BTF`/`.BTF.ext`
  refeito — **`.BTF_ids` é seção de runtime e fica**, nos 4 módulos que a
  têm: `nf_flow_table`, `fou`, `tcp_bbr`, `tcp_dctcp`; hardlink do dir
  `-ksu` atualizado, nlink=2).
- Log: `/tmp/opencode/q-TE.log` (volátil — /tmp é limpo no reboot do host).
- **Retest real (v4): ✅ SUCESSO** — usuário confirmou boot completo
  "funcionou perfeitamente" na entrada KSU (2026-11-10). Diagnóstico do
  boot 3 fechado: nenhum resíduo.
- Nota build: guard de jobs agora é **swap-aware** (RAM < 12 GB com swap
  ≥ 32 GB → até `-j12`, nproc=12; sem swap folgado → cap 4, OOM histórico).

## Correção crítica: como o `vendor_dlkm` é montado (descoberta de 2026-11-09)

Mistério resolvido lendo o código-fonte oficial do `generic_init`
(`LineageOS/android_vendor_mainline@lineage-24.0`,
`services/generic_init/dynamic_mount_handler.cpp`):

- **Nenhum fstab estático menciona `vendor_dlkm.img`**. Com
  `mount_system=imgs`, o `DynamicMountHandler` escaneia o android_dir
  (cada arquivo `*.img`, case-insensitive) e casa **pelo nome do arquivo**:
  tira a **última extensão** e compara com a lista exata
  `android_system_partitions = {product, system, system_dlkm, system_ext,
  odm, odm_dlkm, vendor, vendor_dlkm}` (e `android_userdata_partitions` =
  `{cache, userdata, metadata}`).
- Consequência: `vendor_dlkm.ksu.img` → stem `vendor_dlkm.ksu` →
  `ImageType::UNKNOWN` → **imagem silenciosamente ignorada**,
  `/vendor_dlkm` não monta e os **3973 módulos** (segundo
  `docs/installation.md`, *"All kernel modules are installed in the
  `vendor_dlkm` partition"*) não carregam no estágio 3 → boot KSU
  quebraria (gráficos/áudio/etc. sem driver).
- `firmware.img` (ou `linux-firmware.img`) é **obrigatório** quando
  `mount_firmware=img` — ausência ⇒ `LOG(FATAL)` ("Firmware image was not
  found").
- `androidboot.android_dir` dá o diretório preferido procurado em cada
  block device (fallbacks: `android`, `boot/android`). Nada mais no sistema
  consome esse parâmetro (grep no device tree confirma).
- `firmware.img` **não pode** ser renomeado; e renomear o `vendor_dlkm.img`
  original colocaria a **stock** no mesmo problema (vendor_dlkm.stock TAMBÉM é
  UNKNOWN).

### Solução aplicada: android_dir paralelo (simulink)

Criado `/mnt/p7/android-Generic_x86_64-ksu/` — só isto entra nele:

| Conteúdo | Tipo | Aponta para |
|---|---|---|
| `vendor_dlkm.img` | **hardlink** (inode igual, 0 bytes) | `vendor_dlkm.ksu.img` do dir original |
| `system.img`, `vendor.img`, `system_dlkm.img`, `firmware.img` | symlink | `../android-Generic_x86_64/<nome>` |
| `cache`, `metadata`, `userdata` | symlink | `../android-Generic_x86_64/<dir>` |

Por que funciona: `directory_entry::is_regular_file()`/`is_directory()`
**seguem** symlinks; `mount()` (loop com `open()` do arquivo) também. O
`firmware.img` presente por symlink satisfaz o `mount_firmware=img`; os
symlinks de `cache/metadata/userdata` alimentam o `mount_userdata=
bind_mount_dir` (binds gerados a partir de `android_dir_have_subdirs`).
O dado persistente continua **compartilhado** com a stock (é a mesma pasta
`userdata`). A stock fica **100% intocada** (usa o dir original).

GRUB: na entrada KSU trocou-se apenas
`androidboot.android_dir=android-Generic_x86_64` →
`androidboot.android_dir=android-Generic_x86_64-ksu` (linha do `linux …
kernel.ksu`; `android_dir_dev=UUID=06a5aae3…` permanece — mesmo
partição).

Rollback da correção (sem boot KSU): remover o dir `-ksu` e reverter
a linha 31 do grub.cfg (`android_dir=android-Generic_x86_64`) —
ou restaurar o `grub.cfg` do backup.

Se um dia atualizar `vendor_dlkm.ksu.img`: regenerar e o hardlink já
reflete (mesmo inode). Manter os dois nomes sempre.

## Plano em uma frase

Integrar o **KernelSU v3.3.1** no **kernel idêntico ao instalado**
(Android mainline 7.2.0+, x86_64) e substituir kernel + módulos no boot GRUB,
com entrada GRUB separada e rollback fácil.

## Por que integrar o kernel (e não LKM)

1. O KernelSU **não suporta oficialmente kernels non-GKI desde v1.0** — para
   GKI ele distribui LKM pré-compilado; para kernels customizados, a integração
   na fonte (`CONFIG_KSU`) é o caminho (guia oficial "how-to-integrate-for-non-gki").
2. **O LKM oficial não bate** com o kernel 7.2.0+ do projeto (não é GKI).
3. Problema moderno de **x86_64**: o endurecimento do dispatcher de syscall
   quebra o hook do KernelSU — corrigido oficialmente pela opção de build
   `CONFIG_KSU_X86_PATCH_SYSCALL_DISPATCHER=y` (KSU ≥ 3.3.0; a nossa versão ada é
   **v3.3.1** ✓).

## Fidelidade da reprodução do kernel

| Item | Valor (igual ao instalado) |
|---|---|
| Árvore | `android.googlesource.com/kernel/common`, branch `android-mainline` |
| Versão | 7.2.0+ (bzImage "Linux version 7.2.0+ … Tue Oct 20 00:00:00 UTC 2026") |
| **Pin** | **`a2a0ccf4c10574fde950e554abffd9bdc9aec676`** ("Merge tag 'v7.2' into android-mainline", 2026-10-02) — do release notes oficiais do repo (20261020: "Linux kernel: based on android-mainline v7.2.0 @ a2a0ccf4c105") |
| Config | extraída/com `extract-ikconfig` do kernel instalado (11980 linhas, arquivo `/tmp/opencode/kernel-current.config`, vai para `configs-extra/kernel-current.config`) |
| Patches LineageOS | topic `mainline-kernel`: `drm/vmwgfx ABGR8888` (423579), `HACK selinux Force permissive` (**essencial** p/ cmdline `androidboot.selinux=permissive`; 464426), `Revert virtio context` (496668) |
| Rust | rustc 1.93.1 (rustup pinado — mesma versão do toolchain Android) |
| Clang | distro clang 23.1.4 (o clang original era AOSP 22.0.2, build 15071444, **não** é baixável de ci.android.com sem endpoint autenticado; nuance documentada — `CONFIG_CC_VERSION_TEXT` mudará) |
| LTO | `LTO_NONE` (config atual); sem dependência de linker especial |

### Config: receita "oficial" do dispositivo (referência)

`gki_defconfig` + fragments em série: `pre-debian.config` →
`debian-filtered.config` (debian config/config + amd64/config filtrado pelos
prefixos de `debian_kconfig_sections_blacklist.txt`) → `fix-build.config` →
`fragments/y/fbcon.config` → `customizations.config`.

**Na prática, este preparo usa a config extraída do kernel instalado** (que já
É a geração dos fragments acima), reescrevendo apenas os deltas do KSU — mais
fiel do que refazer a fusão por fora.

## Deltas no .config (vs kernel instalado)

```txt
CONFIG_KSU=y                               # KernelSU builtin (hook via kprobe; depende KPROBES+EXT4)
CONFIG_KSU_X86_PATCH_SYSCALL_DISPATCHER=y  # fix x86_64 do endurecimento do dispatcher
CONFIG_EXT4_FS=y                           # KSU=y exige EXT4 builtin (era =m)
CONFIG_EXT4_FS_SECURITY=y                  # boot 3: xattr selinux no ext4 (mount de payload APEX); era =y no stock
CONFIG_EXT4_FS_POSIX_ACL=y                 # boot 3: restaurado junto (era =y no stock)
CONFIG_X86_KERNEL_IBT=n                    # fix #CP do initcall KSU (indireção via kallsyms)
CONFIG_MODULE_ALLOW_BTF_MISMATCH=y         # fix "Missing block device": BTF de módulo divergente não aborta insmod
```

O `extra_configs` do KSU (DEBUG off, MANAGER on) fica no default. **Boot 3**:
os deltas `m→y` têm efeitos colaterais no `olddefconfig` (opções dependentes
sem `default y` caem para `n`) — por isso todo delta é reafirmado
explicitamente **e** com guarda pós-olddefconfig.

## Sistema de módulos (MODVERSIONS=y) — é preciso trocar TUDO em conjunto

- Config atual: `CONFIG_MODVERSIONS=y`, 3977 `.ko` no `vendor_dlkm.img`,
  657 `.ko` no ramdisk (`lib/modules/`, streams cpio concatenados).
- **Trocar apenas o bzImage quebraria todos os módulos** ("disagrees about
  version of symbol'): os CRC de MODVERSIONS vêm do build original.
-.logo, o plano de instalação repacoteia:
  1. `vendor_dlkm.img` (EROFS: troca os 3977+ .ko pelo novo set — mesma técnica
     do patch do vendor.img, erofs extract → repack lz4;sítios, backup sideload);
  2. ramdisk: `ramdisk-all-combined.img` (LZ4 v0.1-v0.9 truncado concatenado com
     3+ string cpio concatenadas; edita entradas `lib/modules/*.ko` com
     re-serializer interno).
- `modules.load*` do device tree não muda (nomes iguais).
- **BTF**: todos os `.ko` que o nosso kernel carrega vão com `.BTF`/`.BTF.ext`
  removidos (`objcopy`) — split-BTF só valida contra o vmlinux do build de
  origem dos módulos; ver seção "Boot 2" acima.

## Repositório de build (~/android17/build/ksu)

| Dir | Conteúdo | Status |
|---|---|---|
| `kernel-mainline/` | clone (blob:none) do android-mainline do googlesource | em andamento |
| `debian-linux/` | sparse clone (`debian/latest`) p/ gerar filtered.config | ✅ 24 MB |
| `KernelSU/` | tiann/KernelSU **v3.3.1** (checkout) | ✅ |
| `KernelSU-manager.apk` | APK do gerenciador (instalação no Android) | ✅ 13,6 MB |
| `ksud-x86_64` | CLI ksud (host, fallback) | ✅ |
| `android_device_mainline_common/` | glue de docs de kernel do projeto | ✅ |
| `android_kernel_mainline_configs/` | fragments (fbcon, etc.) | ✅ |
| `lineage-patches/` | 3 patches do topic mainline-kernel | ✅ |
| `out/` (a criar) | build dir + .config | — |

## Próximos passos

1. ~~build~~ ✅ **bzImage 7.2.0+ @ a2a0ccf4c105 com KSU builtin validada** (ikconfig: `KSU=y`,
   `KSU_X86_PATCH_SYSCALL_DISPATCHER=y`, `EXT4_FS=y`, `RUST=y`, `AX88796B_RUST_PHY=y`, `QT2025=m`)
2. ~~modules_install~~ ✅ **3973 .ko** (3977 − ext4/jbd2/mbcache/crc16 builtin = mesmo conjunto, 4 builtin)
3. ~~install_kernel_ksu.sh~~ ✅ **artefatos gerados em p7** (22 s, sanity: 3973 .ko vendor flat,
   ramdisk 653 trocados + 4 builtin removidos, 3 trailers, round-trip OK, LZ4 legacy preservado)
4. ~~`--apply-boot`~~ ✅ **aplicado** (kernel.ksu + repack vendor_dlkm/ramdisk
   a partir do modstaging reutilizado; GRUB idempotente — entrada já existia,
   apenas validada; dir `-ksu` idempotente; p7 remontada após reboot do host)
5. ✅ **Boot de teste v4 (máquina real): SUCESSO** — usuário confirmou
   (2026-11-10): boot KSU completo, sem fatal. Diagnóstico em cadeia dos
   boots 1–3 (capítulos acima). Pós-boot: sideload `KernelSU-manager.apk`
   (deve mostrar "Trabalhando") + teste `su` no Terminal — confirmar se já
   feito.
6. ⏳ Rota B opcional (LKM): manter kernel+módulos originais e adicionar só `kernelsu.ko`;
   viabilidade de CRC MODVERSIONS **provada** (wireguard.ko orig vs rebuild: CRC idênticas).
7. ⏳ **Fase 2 — aceleração gráfica**: diagnóstico **completo** + **teste
   zero-artefato ✅** (Vulkan com ANV/Iris confirmado pelo usuário; mecanismo
   apexd bootstrap×principal documentado) + **fix #3 aplicado** (vendor.ksu.img
   com os 5 XMLs de feature, hardlink no dir `-ksu`, rollback pronto).
   **Pendente**: usuário limpar a persist prop, rebootar na entrada KSU e
   validar `pm list features | grep -i vulkan` (agora via vendor) + app Vulkan
   (ANV deve continuar). Opcional depois: `ro.hwui.use_vulkan=true` (#4).

## Lições do build real (2026-11-09)

- `rustup toolchain minimal` **não inclui `rust-src`** → kernel exige fonte da stdlib;
  sem ela `CONFIG_RUST` é derrubado silenciosamente no `olddefconfig` (e os drivers
  Rust `ax88796b_rust`/`qt2025` desaparecem do conjunto).
- `olddefconfig` precisa do `PATH` do rustc 1.93.1 **antes** do parse; guardas no script.
- Kconfig AOSP exige `KCONFIG_EXT_PREFIX` (stub vazio resolve em build standalone).
- `MODVERSIONS` CRCs são **reproduzíveis entre compilers** (AOSP clang vs distro clang)
  se a árvore+config forem idênticas — provado comparando `.ko` orig vs rebuild.
- `modules_install` usa layout `kernel/…` mas o `vendor_dlkm` é flat → flattening
  por basename no repack (e cuidado com bytes vs str no mapeamento Python).
- RAM 7 GB: `-j4` obrigatório para os módulos (full `-j` mata com OOM).
- Cpio newc: preservar header de 110 bytes byte-a-byte (só campo `size` reescrito,
  hex lowercase) → round-trip byte-idêntico garantido.

## Riscos e mitigação

- **Bootloop**: opção GRUB nova separada; kernel original permanece no menu.
- **Modules CRC**: todo o conjunto é rebuildado junto (ver lista acima).
- **SELinux permissive** já ativo (HACK do patch 464426) — KSU roda livre.
- **Clang diferente**: diferença binária esperada; funcionalmente neutra ((o
  `CONFIG_CC_VERSION_TEXT` muda e as flags de módulo se realinham no rebuild)).
- **KSU hooks**: `CONFIG_KPROBES=y` e `CONFIG_KPROBE_EVENTS=y` já presentes.

## Referências

- guia oficial KSU non-GKI (arquivado): `website/docs/guide/how-to-integrate-for-non-gki.md`
- guia x86_64 (`KSU_X86_PATCH_SYSCALL_DISPATCHER`): `website/docs/guide/x86_64-support.md`
- docs do projeto: `device/mainline/generic/docs/build.md`, `build-dependencies.md`,
  `docs/KERNEL.md` (device/mainline/common)
- doc de instalação KSU: `website/docs/guide/installation.md`

---

# Fase 2 — aceleração gráfica: como a ROM usa a GPU (2026-11-10)

> Objetivo: descobrir como o Android Generic x86_64 usa aceleração gráfica
> (usuário observou "só OpenGL ES, sem Vulkan") e mapear o caminho para
> habilitar Vulkan. Diagnóstico **fechado em código** (fonte do
> `hardware_detect` em `me-cafebabe-aosp-mainline/android_device_mainline_generic`,
> do apexd em `LineageOS/android_system_apex @ lineage-24.0`, e dos apexes em
> `android_device_mainline_common/apex/`).

## Estado real no boot KSU (hardware)

Log real (`early_logcat.log` da seção do boot 23:02, extraída em
`/tmp/opencode/lastboot.log`) + vendor.img:

| Camada | Componente | Estado |
|---|---|---|
| GPU | Intel Iris Xe (RPL-P, PCI `8086:a7a1`, Gen 9+ p/ o detector) | ✅ |
| Kernel | `i915.ko` do vendor_dlkm (carregado por `generic_init` via cadeia `drm.ko` → `drm_kms_helper` → `drm_display_helper` → i915; o host usar `xe` é irrelevante) | ✅ card0 + renderD128 |
| Detecção | `hardware_detect` (`/vendor/bin/hardware_detect`): "DRM device card0 is i915", "Intel device ID 0xa7a1 is Gen 9+", `ProcessBootOverrides(): Override hwc_apex from 1 to 2` (vem de `ro.boot.hwc_apex=2` no vendor/build.prop — fix do maintainer p/ issue #3, que é **deste mesmo hardware**: Galaxy Book4, i5-1335U, a7a1) | ✅ |
| GLES/EGL | `ro.opengles.version=196610` (3.2), `ro.hardware.egl=mesa` → **GLES 100% por hardware**: SurfaceFlinger reporta `renderer Mesa Intel(R) Iris(R) Xe Graphics (RPL-U), OpenGL ES 3.2 Mesa 26.2.3` | ✅ |
| Vulkan ICD | `ro.hardware.vulkan=intel` → carregaria `/vendor/lib64/hw/vulkan.intel.so` (**Mesa ANV**, hardware) | ✅ setado, ❌ nunca usado |
| Vulkan APEX | `ro.boot.vendor.apex.org.lineageos.device.graphics.vulkan=…no_apex` (escolha padrão) | ❌ |
| HWUI | `ro.hwui.use_vulkan=` vazio → renderiza em GLES (comportamento default correto) | — |
| Gralloc | APEX `minigbm_upstream`; warn "Minigbm generic backend is unset" (`vendor.minigbm.generic_backend` sem valor — inofensivo p/ GLES, pode importar p/ Vulkan) | ⚠️ |
| HWComposer | APEX `drmfb` (compositor drmfb-composer3 via override) | ✅ |

Tudo setado **sem erros** (`ApplySelections` não logou
"Failed to set some properties"). Conclusão: **aceleração gráfica já é
plenamente por hardware para GLES**; o que falta é Vulkan — e a causa é
exatamente conhecida (abaixo).

## Causa raiz do "sem Vulkan" (fechada em código)

1. `FEATURE_VULKAN` para apps vem de XMLs `<feature name="android.hardware.vulkan.*">`
   em diretórios `etc/permissions/` — que o PackageManager escaneia em
   system, vendor, product, odm, system_ext **e em todos os APEXes** (montados
   como partição system).
2. Verificado nas imagens: `system.img` não tem **nenhum**
   `android.hardware.*.xml`; `vendor/etc/permissions/` tem 8 XMLs, **nenhum de
   Vulkan**.
3. Os 5 XMLs de feature existem **só dentro do payload do apex
   `…vulkan.swiftshader`** (`/etc/permissions/`: `vulkan.version-1_3`
   (4206592 = 0x403000 = Vulkan 1.3), `vulkan.level-1`, `vulkan.compute-0`,
   `android.software.vulkan.deqp.level-latest`,
   `android.software.opengles.deqp.level-latest`).
4. Mas o `hardware_detect` escolhe o apex **`no_apex`** — que é **vazio por
   design** (`Android.bp` dele: só o rc `"# Empty file for now"`; o "for now"
   indica que a declaração de feature para o caminho de hardware Vulkan nunca
   foi terminada upstream). Detecção de hardware ⇒ `vulkan_apex` fica `Unset`
   ⇒ default `No_apex` (switch em `selections.cpp:188-198`).
5. Resultado: ICD ANV (`ro.hardware.vulkan=intel`) setado e ocioso, feature
   nunca declarada → **apps não veem Vulkan**; HWUI nem tenta.

## Mecanismos (verificados no código)

### Seleção multi-install de APEX (apexd)
- Props de seleção: `persist.vendor.apex.<apex_name>` (**tem prioridade**,
  `kApexSelectPersistPrefix` checado primeiro em `apex_constants.h:92-97`)
  e `ro.boot.vendor.apex.<apex_name>`. Valor `"none"` desabilita o apex;
  valor normal = **nome completo do apex sem `.apex`**
  (`ConsumeApexPackageSuffix(Basename(path)) != select_filename` ⇒ skip,
  `apex_file_repository.cpp:117-123`). Sem seleção com 2 candidatos ⇒
  `LOG(FATAL)` em `apexd.cpp`.
- O PMS escaneia todos os APEXes ativos como partição system ⇒ `etc/permissions/`
  dentro de apex vale como feature (é assim que o caminho swiftshader declara Vulkan).

### `hardware_detect` (fonte: `services/hardware_detect/{hardware_detect,selections}.cpp`)
- `ProcessBootOverrides()` lê `ro.boot.<nome>` e sobrescreve a seleção
  detectada (**inteiro = valor do enum**): `gles_version`, `hw_egl`, `hw_vulkan`,
  `gralloc_apex`, `hwc_apex`, `usb_gadget_apex`, `vulkan_apex`,
  `minigbm_generic_backend`, `sf_native_window_buffers_format`
  (`selections.cpp:84-108`).
- Enums (`selections.h`): `HwVulkan`: Unset=0, Asahi=1, Broadcom=2,
  Freedreno=3, Imagination=4, **Intel=5**, Intel_hasvk=6, Lvp=7, Nouveau=8,
  Panfrost=9, Radeon=10, Virtio=11. `VulkanApex`: Unset=0, **No_apex=1**,
  **Swiftshader=2**. `HwEgl`: Unset=0, Angle=1, Mesa=2. `HwcApex`: Unset=0,
  Drm=1, DrmFb=2, Empty=3.
- Modos forçados: `ro.boot.graphics=swiftshader` (ANGLE + GLES 3.1 + apex
  Swiftshader) / `=llvmpipe` (Mesa llvmpipe + GLES 3.2 + ICD lvp);
  `androidboot.use_fb_display` (framebuffer).
- Timing: setprops às 04:02:02.19x, **antes** do apexd ler (02.27x) —
  `ro.boot.*` sobrescrito em runtime, mas **persist vence** no apexd.

### Verificação de payload de APEX (mata uma das opções de fix)
- `MountPackageImpl()` chama `apex.VerifyApexVerity(bundled_pubkey)`
  **incondicionalmente** (`apexd.cpp:538`), mesmo com `mount_on_verity=false`
  para apexes pré-instalados (`apexd.cpp:496-507`). `VerifyApexVerity` roda
  `avb_vbmeta_image_verify` do `apex_payload.img` com a chave embutida
  (`apex_file.cpp:241+`).
- ⇒ **Editar payload de apex = rejeição no boot** (não temos a chave privada
  `com.android.hardware`). O vendor.img, em contraste, é EROFS **sem
  verificação de assinatura** — repack viável (fluxo já provado no
  vendor_dlkm em 2026-11-09/10).

## Caminhos para habilitar Vulkan (opções)

| # | O quê | Custo/risco | Resultado |
|---|---|---|---|
| **1** | **Teste zero-artefato via persist prop**: com `su` no Terminal Android, `setprop persist.vendor.apex.org.lineageos.device.graphics.vulkan org.lineageos.device.graphics.vulkan.swiftshader` + reboot. persist vence o `ro.boot.*` setado pelo `hardware_detect` (que não toca em persist) | Zero artefato; revert = `setprop persist.vendor.apex.… ''` (ou reset) | Apex Swiftshader ativo ⇒ XMLs ⇒ `FEATURE_VULKAN`; driver = `pastel` (SwiftShader, **software**) setado pelo rc do apex (`on init`) — mas atenção: o `hardware_detect` roda ~2 min depois e re-seta `ro.hardware.vulkan=intel`, então o driver efetivo tende a ser **ANV de hardware** mesmo com o apex swiftshader ativo (empírico — é parte do que o teste revela) |
| **2** | **Teste zero-artefato via cmdline**: `androidboot.vulkan_apex=2` no GRUB (override documentado de `vulkan_apex` ⇒ Swiftshader; `hw_vulkan` vai a Unset) | Zero artefato; revert = remover da cmdline | Idem #1, mas sem persist no /data |
| **3** | **Fix de verdade — repack do vendor.img**: extrair EROFS, adicionar os **5 XMLs** (já extraídos do payload swiftshader p/ `/tmp/opencode/vk-xmls/`) em `/vendor/etc/permissions/`, `mkfs.erofs -zlz4` (mesmo fluxo do vendor_dlkm), instalar como `vendor.ksu.img` + hardlink no dir `-ksu` + rollback em `backup-p7-*` | Repack EROFS (sem assinatura); rollback idêntico ao já praticado | `FEATURE_VULKAN` declarado **com** apex `no_apex` e ICD ANV ⇒ **Vulkan 1.3 por hardware** (Mesa/ANV na Iris Xe) — o design que o upstream deixou incompleto |

**Resultado do teste zero-artefato (#1): ✅ CONFIRMADO PELO USUÁRIO + LOG
(boot 05:01, `early_logcat.log`)** — com
`persist.vendor.apex.org.lineageos.device.graphics.vulkan =
org.lineageos.device.graphics.vulkan.swiftshader`:

- **Mecanismo em duas fases** (relevante p/ entender qualquer divergência de
  apex em boot): `apexd-bootstrap` roda **antes** de montar `/data`, logo
  **não vê persist props** → selecionou `no_apex` (leu o `ro.boot.*` que o
  `hardware_detect` acabara de setar); o **apexd principal** roda depois de
  `/data` montado → vê a persist prop → **"Skipping APEX … no_apex"** =
  selecionou **swiftshader**. As ativações do bootstrap vivem em namespace
  de mount próprio e são **descartadas** — a seleção do apexd principal é a
  que vale. Ativação **sem erros** (0 "Failed to activate"/"is not empty").
- **Vulkan funcionou de verdade**: o rc do swiftshader **não rodou** (trigger
  `on init` já tinha passado na ativação tardia) ⇒ `ro.hardware.vulkan`
  permaneceu **intel** (setado pelo `hardware_detect` às 05:01:54.145) ⇒ o
  ICD usado foi o **ANV da Iris Xe** (hardware) — confirmado pelo usuário
  ("ativou toda a stack vulkan incluída a da iris"). E `ro.cpuvulkan.version`
  / `ro.vulkan.apex` **não existiram** — prova de que não são necessários
  para o caminho ANV.
- Estado residual do teste: apex swiftshader ativo (divergência
  bootstrap=`no_apex` vs principal=`swiftshader`) + 32 MB de libs pastel
  montadas à toa. **Para o estado final limpo: limpar a persist prop e
  rebootar** — a feature passa a vir dos XMLs do vendor (#3).

**Aplicação do fix #3 (2026-11-11 ~00:07): ✅** — `install_vendor_vulkan.sh`
(binário corrigido: lista original capturada **antes** de copiar os XMLs):
`vendor.ksu.img` (2074 inodes = 2069 + **delta exatamente 5 XMLs** em
`etc/permissions/`, lz4, mtime preservado), hardlink `vendor.img` no dir
`-ksu` (nlink=2), stock `vendor.img` intocado (backup em
`backup-vendor-vulkan-20261110/vendor.img.pre-vulkan`; rollback =
`--rollback`). Retest pendente no real: **limpar a persist prop + reboot
entrada KSU + `pm list features | grep -i vulkan`** (features devem
permanecer, agora via vendor; apex volta a `no_apex` e o driver continua
ANV/intel).
| **4** | (pós-3, opcional) `ro.hwui.use_vulkan=true` | HWUI de todo app passa a Vulkan — maior risco de artefatos; testar depois de #3 estabilizar | HWUI renderiza via VK |

Observações: o `ro.vulkan.apex` (setado só pelo rc do swiftshader) é
consumido pelo caminho de ICD-in-apex (pastel); para o ICD de vendor (ANV)
o `ro.hardware.vulkan` padrão basta. O warning do minigbm backend pode
importar p/ Vulkan (gralloc) — se #3 ativar Vulkan com falhas de buffer,
o próximo passo é setar `vendor.minigbm.generic_backend` (`dmabuf_heap`,
`dumb_generic`, `gbm_mesa` ou `staging`).

Fontes: `/tmp/opencode/dev-generic/` (clone raso do device tree),
`/tmp/opencode/apex-src/` (clone apexd), `/tmp/opencode/vk-xmls/` (XMLs),
`/tmp/opencode/vk-apex/{no,ss}/apex_payload.img` (payloads ext2, lidos via
`debugfs`) — **voláteis** (/tmp limpo no reboot do host).

---

# Fase 3 — distribuição: ISOs live + repositório GitHub (2026-11-11)

> Verificação do fix no real **pulada a pedido do usuário** (o teste
> zero-artefato já havia validado a feature via PMS + ANV no hardware real).
> Objetivo: publicar ISOs e repositório.

## ISOs

Base: **ISO oficial 20261020** (`/home/iris/lineage-24.0.iso`,
2 841 491 456 bytes = exatamente as duas partes `lineage-24.0_aa/_ab` do
release upstream — **verificada byte a byte** contra elas).

### Estrutura da ISO live (do projeto)
- GRUB (El Torito BIOS `/boot/grub/i386-pc/eltorito.img` + EFI `/efi.img`,
  grub2-MBR híbrido, `-hfsplus`, Rock Ridge **sem Joliet**, `-V ISOIMAGE`)
- `android-Generic_x86_64/` com `kernel`, `ramdisk-all-combined.img`,
  `system.img`, `system_dlkm.img`, `vendor.img`, `vendor_dlkm.img`,
  `firmware.img` (+ `.disk/<uuid>`, `System/Library/CoreServices`,
  `mach_kernel` vazio, `efi/`)
- Modo live: `androidboot.live=1 mount_system=imgs mount_userdata=tmpfs`
  (**sem userdata persistente por natureza**) — `generic_init` acha o dir
  Android no próprio dispositivo (QEMU: `/dev/block/sr0`); suporte a
  Ventoy/loopback GRUB via `androidboot.android_iso_uuid`
- `grub.cfg` oficial já expõe os overrides gráficos (gralloc_apex,
  hwc_apex, minigbm, graphics=swiftshader/llvmpipe, use_fb_display)
- Opções de criação capturadas com `xorriso -indev … -report_system_area
  as_mkisofs` → rebuild fiel com as mesmas opções

### ISO 1 — `lineage-24.0-20261111-UNOFFICIAL-0xCAFEBABE-Generic_x86_64-live-ksu-vulkan.iso` (2 841 540 608 bytes)
Mesma estrutura com 4 arquivos trocados: `kernel` ← kernel.ksu,
`ramdisk-all-combined.img` ← ramdisk KSU, `vendor_dlkm.img` ← vendor_dlkm KSU,
`vendor.img` ← vendor.ksu.img (**com os 5 XMLs Vulkan**); system/firmware
stock. `grub.cfg`: títulos "(KernelSU + Vulkan)" + entrada de diagnóstico
`androidboot.vulkan_apex=2` no submenu de gráficos.
**QEMU: VERDE** — GRUB auto-boot serial, android dir no sr0, KSU ativo,
`Activated 10 packages` (52 ms), 0 Mounting failed, zygote ok. No QEMU o
`hardware_detect` escolhe `lvp_mesa3d` (correto: sem GPU real); no hardware
real detecta `intel`/ANV.

### ISO 2 — `lineage-24.0-20261020-original.iso`
A original oficial **sem modificações** (re-host; partes renomeadas p/
clareza). Nota: o `vendor.img` original tem 201,5 MB — o do SSD (219 MB,
`.before_ucm`) já era a versão da sessão anterior; a ISO é a referência
stock.

## Repositório
**https://github.com/exfurr-bash/Lineage24-for-x64** (public) — commit
`7fb8a8d`: README (EN/PT-BR), `KSU-prep.md`, `build_kernel_ksu.sh`,
`install_kernel_ksu.sh`, `install_vendor_vulkan.sh`, `make_iso.sh` (receita
reprodutível da ISO: extrai esqueleto da oficial, troca as 4 imagens, ajusta
grub.cfg, xorriso com as opções capturadas), `patch_vendor_*.sh`,
`collect_bootloop_logs.sh`, docs issue3/SOM, `vendor-vulkan-xmls/`.
`.gitignore` exclui build/ (24 GB), backups, `extracted/`, `*.iso`, `*.img`.

## Release
Tag `lineage-24.0-20261111-UNOFFICIAL-0xCAFEBABE-Generic_x86_64-live-ksu-vulkan`
com: ISO1 em 3 partes (`_aa/_ab/_ac`, 1,42 GB + 1,42 GB + 48 KB), original
em 2 partes (`_aa/_ab` — a oficial tem exatamente 2× 1,42 GB, sem resto),
`sha256sums.txt` (6 entradas: 2 ISOs completas + 4 partes) e notas (EN;
instruções de `cat` + tabela de mudanças + contexto do fix Vulkan + KernelSU
manager via sideload). Limite de asset do GitHub = 2 GiB → por isso partes.

**PUBLICADO**: <https://github.com/exfurr-bash/Lineage24-for-x64/releases/tag/lineage-24.0-20261111-UNOFFICIAL-0xCAFEBABE-Generic_x86_64-live-ksu-vulkan>
(6 assets, todos `uploaded`). Correção pós-upload: as 2 entradas da original
tinham caminho absoluto local no `sha256sums.txt` — corrigido para nomes
relativos e reenviado com `gh release upload --clobber`. Verificação fim-a-fim
do fluxo do usuário: `sha256sums.txt` baixado do release → `cat` das partes →
`sha256sum -c` **8/8 SUCESSO** + `cmp` das ISOs remontadas == locais byte a
byte; asset `_ac` baixado do release confere com o local. Limpeza feita
(`stage/`, `stage-test/`, `orig-verify/`, `test-ksu-vulkan.iso`,
`user-sim/`); em `/home/iris/iso-build/` ficaram só a ISO1 + partes +
`sha256sums.txt` + `release-notes.md`.

Lembretes: a persist prop de diagnóstico
(`persist.vendor.apex.org.lineageos.device.graphics.vulkan`) **continua setada**
no dispositivo (limpar é opcional — o fix do vendor já está ativo na entrada
KSU); o APK do **KernelSU manager não vai nas ISOs** — sideload dos releases
do KSU; `ro.hwui.use_vulkan=true` ficou como item futuro opcional.

## Status final do projeto (11/11/2026)

**Confirmado pelo dono: nenhum problema no Android em uso real.** Log do boot
mais recente (`early_logcat.log`, 05:01 de 11/11 — 15 sessões registradas,
todas kernel `7.2.0+`): `KernelSU: welcome` (32680), `hardware_detect: Set
Vulkan module to intel` (ANV/Iris Xe na máquina real, como projetado),
APEX `no_apex` (features vindas do vendor), **0 `Mounting failed`**. Itens
1 (limpar persist prop), 3 (comentário upstream) e 4 (CI) ficaram
**deliberadamente não feitos** a pedido do usuário; item 2
(`ro.hwui.use_vulkan=true`) permanece como experimento futuro opcional.

