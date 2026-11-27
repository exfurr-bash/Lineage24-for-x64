# Migração futura para a base 20261122

Este documento registra uma migração futura. O checkout continua fixado em
20261020 e kernel 7.2; esta nota não executa nem aprova a troca de base.

## Pins conhecidos

| Item | Base atual | Alvo futuro |
| --- | --- | --- |
| Release Generic_X86_64 | 20261020 | 20261122 |
| Série do kernel upstream | 7.2 | 7.3 |
| Commit do kernel citado no release | a2a0ccf4c10574fde950e554abffd9bdc9aec676 | 5201b511c7c80 |
| Estado | default em config/sources.lock | registrado como RELEASE_NEXT_* |

Os nomes dos assets e hashes conhecidos do alvo estão no lock. O release
20261122 foi publicado depois da base atual. A versão curta do commit 7.3
precisa ser expandida e conferida no upstream antes de qualquer alteração do
pin ativo.

## Checklist antes de mudar a base

1. Baixar a release candidata em área de cache e validar os hashes publicados.
2. Inspecionar o layout da ISO, nomes das partições, GRUB, kernel stock,
   ramdisks e imagens EROFS.
3. Fixar o commit completo do kernel e comparar a config extraída com o
   REFCONFIG atual.
4. Confirmar compatibilidade da tag e commit do KernelSU com o novo kernel.
5. Recompilar kernel e módulos; verificar versão, ABI e metadados depmod.
6. Regerar as imagens vendor, testar o HAL desktop, firmware e a cadeia de
   módulos Bluetooth.
7. Regerar a imagem GApps separada e conferir o manifesto, labels SELinux,
   APEX e tamanho EROFS.
8. Criar ISOs vanilla e GApps e testar ambas no QEMU com os critérios de
   scripts/test_qemu.sh.
9. Atualizar os pins ativos somente após revisar logs, checksums e diffs.
10. Atualizar este documento, docs/SOURCES.md e as notas da release.

Até a conclusão dessa validação, mantenha BASE_RELEASE=20261020 e o commit
7.2 como defaults. O argumento RELEASE=20261122 do downloader serve para
obter e inspecionar a fonte candidata; isso, sozinho, não valida uma migração.
