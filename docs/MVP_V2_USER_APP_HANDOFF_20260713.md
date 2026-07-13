# Vai Rodar - User App MVP V2

Data do release: 13/07/2026

Este documento e o contrato de transicao entre o frontend MVP V2 e o
backend. Nao renomear as pastas ou os arquivos descritos aqui.

## 1. Fonte de verdade e backup

- Frontend de producao: `apps/user-app/index.html`
- Assets do user app: `apps/user-app/assets/`
- Icones de servicos: `apps/user-app/assets/service-icons/`
- Service worker: `apps/user-app/service-worker.js`
- Backup anterior: `archive/user-app-pre-mvp-v2-20260713/index.html`
- Build Netlify: `scripts/build-dist.js`
- Configuracao Netlify: `netlify.toml`

O prototipo local usado para este release nao e fonte de producao. Depois
do deploy, qualquer ajuste deve ser feito em `apps/user-app/index.html`.
Nunca editar `dist/`: essa pasta e gerada por `npm run build`.

## 2. Rotas publicadas

| URL | Origem |
| --- | --- |
| `/` | `apps/user-app/` |
| `/oficinas` | `apps/workshop-entry/` |
| `/oficinas/cadastro` | `apps/workshop-register-supabase/` |
| `/oficinas/painel` | `apps/workshop-app/` |
| `/admin` | `apps/admin-backoffice/` |

O build copia essas aplicacoes para `dist/`. O fallback `/*` aponta para o
user app e deve permanecer como o ultimo redirect de `netlify.toml`.

## 3. Escopo visual do MVP V2

### Home

- Hero focado em descrever o problema e receber propostas.
- Chat IA como acao principal.
- Atalhos `Buscar oficinas` e `Ofertas e Promocoes`.
- Bloco `Como funciona` com tres etapas.
- Seis servicos mais solicitados: oleo, freios, pneus, ar-condicionado,
  estetica e bateria/eletrica.
- Os atalhos de servico abrem o mapa com a categoria correspondente.
- Compra/venda, avaliacao, pecas e emergencia continuam no HTML legado,
  mas ficam ocultos no MVP por `.prototype-hidden`.

### Buscar oficinas

- Busca compacta sem lupa, com botao circular azul de envio.
- Busca tolerante a termos e sintomas por normalizacao/sinonimos locais.
- Dez atalhos visuais de categoria no mapa.
- Botao para limpar a busca/categoria aplicada.
- Mapa Leaflet + CARTO/OpenStreetMap e pins por latitude/longitude.
- Sheet inferior com oficinas, modo lista, selecao multipla e envio da
  mesma solicitacao para oficinas selecionadas.
- Card da oficina com logo, nome, endereco, mensagem, chamada e detalhes.
- Detalhes expansivos para horarios, servicos e contato.
- Reserva pode partir de um servico ou do detalhe da oficina.
- Modo escuro revisado; o mapa continua claro e os fundos dos iconos ficam
  transparentes.
- Avaliacoes ficam ocultas temporariamente.

### Conta, mensagens, propostas e notificacoes

- `Minhas placas` usa visual Mercosul, carrossel horizontal e contador.
- Placas podem ser adicionadas, selecionadas e removidas.
- Campos de placa nos fluxos reutilizam os veiculos do usuario.
- Mensagens mostram o nome real da oficina.
- Mensagem `[RESERVA_CTA]` vira um CTA clicavel `Criar reserva`.
- Propostas priorizam problema + veiculo, com ativas antes das vencidas.
- Propostas vencidas ficam em modulo expansivo.
- Notificacoes podem ser removidas individualmente ou limpas de uma vez.
- Barra mobile prioriza Propostas, Mensagens, Notificacoes e Conta.

### PWA

- Cache atualizado para `vai-rodar-mvp-v2-20260713`.
- O service worker e o manifest continuam na raiz do site apos o build.

## 4. Fluxos de dados existentes

### Chat e solicitacao

1. Usuario escreve no chat.
2. `/.netlify/functions/ai-diagnose` retorna intent, categorias, perguntas
   faltantes e resumo tecnico.
3. O usuario revisa placa, localizacao, descricao e fotos.
4. O frontend cria `service_requests` e, se necessario, `request_photos`.
5. Quando a solicitacao nasce da lista de oficinas, envia
   `selected_business_ids`.
6. Oficinas respondem em `proposals`.
7. Usuario acompanha em Minhas propostas e notificacoes.

### Busca de oficinas

1. O frontend consulta `public_workshops_search`.
2. Categoria, texto e disponibilidade filtram os resultados.
3. Latitude/longitude posicionam os pins.
4. Mensagem usa `conversations` + `messages`.
5. Reserva usa `reservations`.

### Ofertas

1. O frontend consulta `workshop_offers`.
2. Apenas ofertas ativas e dentro da validade devem aparecer.
3. O card abre o modulo de ofertas sem dados falsos.

### Conta

- Perfil: `profiles`
- Veiculos/placas: `vehicles`
- Conversas: `conversations`, `messages`
- Reservas: `reservations`
- Notificacoes: `notifications`

## 5. Integracoes que o frontend preserva

### Netlify Functions

- `ai-diagnose`
- `consultar-fipe`
- `geocode`
- `notify-event`
- `push-config`
- `push-subscribe`

### Supabase

- `profiles`
- `vehicles`
- `public_workshops_search`
- `service_requests`
- `request_photos`
- `proposals`
- `conversations`
- `messages`
- `reservations`
- `notifications`
- `workshop_offers`
- `vehicle_listings`
- `vehicle_listing_photos`
- `vehicle_listing_messages`

### Storage

- `request-photos`
- `vehicle-listing-photos`

## 6. Contratos pendentes para o backend

Nao executar migrations por suposicao. Primeiro comparar o banco real com
os arquivos em `supabase/migrations/`.

### P0 - Solicitacoes dirigidas

O user app ja grava `service_requests.selected_business_ids`. O painel da
oficina le a coluna, mas hoje nao filtra por ela. A regra deve ser:

- array vazio: solicitacao aberta para oficinas compativeis;
- array com IDs: somente oficinas listadas podem ver/responder;
- a regra deve existir em RLS ou RPC, nao apenas no JavaScript.

### P0 - Vista publica de oficinas

O frontend consulta `public_workshops_search` com id, nome, endereco,
cidade, bairro, categoria(s), status, tipo de negocio e coordenadas. O
schema versionado mais antigo da vista nao inclui todos os campos usados
pelo frontend. Antes de alterar, validar a vista real e alinhar em uma
unica migration idempotente.

Campos publicos necessarios no contrato final:

- `id`, `name`, `business_type`
- `address`, `neighborhood`, `city`
- `category`, `categories`
- `open`, `latitude`, `longitude`
- `photo_url` (logo publico)
- `schedule` (horarios reais)
- `home_service`
- catalogo publico de servicos com nome, categoria, preco de referencia,
  duracao e unidade.

Nao expor CNPJ, razao social, responsavel ou dados internos nessa vista.

### P1 - Catalogo de categorias e subcategorias

Hoje `workshops.services text[]` representa categorias, nao o catalogo
detalhado desenhado no novo backoffice. O backend precisa de uma fonte
administrada pelo admin para categorias/subcategorias e de ofertas da
oficina com:

- oficina;
- categoria e subcategoria aprovadas;
- nome do servico;
- preco de referencia opcional;
- duracao opcional;
- unidade `minutes`, `hours` ou `days`;
- ativo/inativo.

O user app ja aceita objetos normalizados via `serviceItems` ou
`serviceCatalog`, mas `loadPublicOffices()` ainda nao os consulta. Migracao,
vista publica e SELECT do frontend devem entrar juntos no mesmo release.

### P1 - Horarios e atendimento a domicilio

- O card ainda mostra horario visual padrao (08:00-18:00) porque a vista
  publica nao entrega `schedule` ao frontend.
- O filtro `A domicilio` existe na UI, mas nao ha coluna versionada
  `workshops.home_service`.
- A solicitacao tambem precisa registrar se o atendimento e na oficina ou
  no endereco do cliente.
- Endereco do cliente so pode ficar visivel para pedido a domicilio.

### P1 - Logo publico

O novo backoffice permite logo, mas o user app so deve trocar o fallback
quando `photo_url` estiver presente na vista publica e no SELECT. Manter o
logo Vai Rodar como fallback.

## 7. Regras para Claude

1. Trabalhar sobre `origin/main` atualizado.
2. Nao renomear `apps/`, `netlify/functions/`, `supabase/migrations/` ou
   `scripts/build-dist.js`.
3. Nao editar `dist/` manualmente.
4. Nao substituir o frontend MVP V2 pelo backup de `archive/`.
5. Nao colocar service role, API keys ou secrets no HTML.
6. Toda tabela nova deve ter RLS e testes por papel.
7. Toda mudanca em vista publica deve preservar os grants de `anon` e
   `authenticated`, expondo apenas dados publicos.
8. Fazer migrations idempotentes e testar com motorista, oficina dona,
   outra oficina, admin e anon.
9. Rodar `npm run build` antes do push e validar as cinco rotas.

## 8. Criterios de aceite do backend

- Solicitacao broadcast chega a oficinas compativeis.
- Solicitacao dirigida chega somente as oficinas selecionadas.
- Oficina pausada nao recebe novos pedidos, mas conserva os antigos.
- Categoria escolhida no home/mapa chega igual em `service_requests`.
- Card publico usa logo, horarios e servicos reais da oficina.
- Filtro a domicilio retorna somente oficinas habilitadas.
- Mensagem, proposta, reserva e notificacao aparecem nos dois lados.
- Nenhum dado de demo aparece quando as tabelas estiverem vazias.
- Falhas de backend mostram erro real; nao exibir sucesso falso.
