# Releases

## Gerar e validar

1. Gere a ISO com make iso ou make iso-gapps.
2. Rode make test-qemu ISO=dist/arquivo.iso; para GApps, use VARIANT=gapps.
3. Prepare partes e checksums com make release ISO=dist/arquivo.iso TAG=nome.
4. Revise os arquivos gerados em dist/release/nome/.
5. Para enviar ao GitHub, use UPLOAD=1. É necessário ter gh instalado e
   autenticado. O envio é uma ação separada e explícita.

Para instalar gh junto das ferramentas de teste, use make bootstrap
WITH_RELEASE=1; depois autentique com gh auth login.

Os assets ISO são divididos em partes com menos de 2 GiB. O pacote contém as
partes, sha256sums.txt, o checksum da ISO completa e SOURCES.json, quando
disponível. Reúna as partes na ordem alfabética do sufixo e valide o checksum
antes de iniciar a ISO.

Use um diretório de saída vazio. O script não apaga um diretório existente;
escolha outro valor para OUTDIR ou arquive os arquivos anteriores.

## Conteúdo de terceiros

O repositório distribui somente scripts, configuração e documentação sob
GPL-2.0-only, além dos XMLs AOSP descritos em
[vendor-vulkan-xmls/README.md](../vendor-vulkan-xmls/README.md). Uma ISO
construída contém componentes de terceiros com seus próprios termos.

Uma ISO GApps inclui aplicativos e binários proprietários do Google. O projeto
não os inclui no Git e o script bloqueia a publicação por padrão. Para
permitir a etapa de upload de uma ISO GApps, passe ALLOW_GAPPS=1 ao alvo
make release; isso apenas remove a trava do script e não concede direitos
de redistribuição. Quem publica deve verificar as permissões aplicáveis aos
componentes incluídos e manter os avisos upstream.

## Conteúdo mínimo do anúncio

- Release base e variante (KernelSU/Vulkan ou KernelSU/Vulkan/GApps).
- Hash SHA-256 da ISO reunida e de cada parte.
- Resultado e log do teste QEMU, incluindo se usou KVM ou TCG.
- Link para as fontes e pins em docs/SOURCES.md.
- Aviso sobre componentes proprietários quando houver GApps.
