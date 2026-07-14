# Prompt Codex — Integração frontend ↔ backend MVP V2 (13/07/2026)

## Contexto

A migration `supabase/migrations/20260713_mvp_v2_backend_contracts.sql` já foi
aplicada no Supabase. O backend agora entrega:

- Vista `public_workshops_search` com colunas novas ao final:
  `photo_url` (text), `schedule` (jsonb), `home_service` (boolean),
  `service_items` (jsonb array).
- Formato de `service_items`: array de objetos
  `{name, category, subcategory, price, duration, unit}` onde `price` é
  numérico ou null, `duration` é numérico ou null e `unit` é
  `minutes | hours | days` ou null. `category` usa os mesmos nomes de
  `allowedCategories`.
- Formato de `schedule`: `{custom: "Segunda-feira: 08:00 às 18:00 | Terça-feira: ... | Domingo: Fechado", mode: "...", district: "..."}`
  (o campo `custom` pode não existir em oficinas antigas — sempre tratar
  como opcional).
- Tabelas novas: `service_categories` (id, name, sort_order, active),
  `service_subcategories` (id, category_id, name, sort_order, active),
  `workshop_services` (id, workshop_id, category_id, subcategory_id, name,
  reference_price, duration, duration_unit, active). RLS: leitura pública
  do catálogo ativo; o dono do workshop gerencia `workshop_services` via
  suas policies.
- Colunas novas: `workshops.home_service boolean` e
  `service_requests.home_service boolean` (default false).
- Bucket Storage novo: `workshop-logos` (leitura pública; escrita apenas
  na pasta `{auth.uid()}/...`).
- Solicitações dirigidas: RLS já filtra `selected_business_ids` no banco.
  Nenhuma mudança de frontend é necessária para isso.

## Regras

- Não renomear pastas nem arquivos. Não editar `dist/`.
- Não colocar secrets no HTML.
- Aplicar cada bloco Buscar/Substituir exatamente sobre os arquivos reais.
- Rodar `npm run build` ao final e validar as 5 rotas.

---

## PARTE A — `apps/user-app/index.html`

### A1. SELECT da vista pública com as colunas novas

Buscar:

```js
    const {data,error}=await sb.from("public_workshops_search")
      .select("id,name,address,city,neighborhood,category,categories,open,business_type,latitude,longitude")
      .limit(50);
```

Substituir:

```js
    const {data,error}=await sb.from("public_workshops_search")
      .select("id,name,address,city,neighborhood,category,categories,open,business_type,latitude,longitude,photo_url,schedule,home_service,service_items")
      .limit(50);
```

### A2. Mapear logo, horários e catálogo reais no objeto office

Buscar:

```js
    offices.splice(0,offices.length,...(data||[]).map((row)=>({
      id:row.id,
      name:row.name||"Oficina Vai Rodar",
      rating:Number(row.rating||0),
      address:[row.address,row.neighborhood,row.city].filter(Boolean).join(", "),
      category:row.category||(Array.isArray(row.categories)?row.categories[0]:"")||"Serviços automotivos",
      open:row.open!==false,
      img:row.photo_url||"assets/vai_rodar_logo_transparent.png",
      services:Array.isArray(row.categories)?row.categories:[],
      businessType:row.business_type||"workshop",
      homeService:Boolean(row.home_service||row.at_home||row.mobile_service||normalizeText(row.service_mode||"").includes("domicilio")),
      latitude:Number.isFinite(Number(row.latitude))?Number(row.latitude):null,
      longitude:Number.isFinite(Number(row.longitude))?Number(row.longitude):null
    })));
```

Substituir:

```js
    offices.splice(0,offices.length,...(data||[]).map((row)=>({
      id:row.id,
      name:row.name||"Oficina Vai Rodar",
      rating:Number(row.rating||0),
      address:[row.address,row.neighborhood,row.city].filter(Boolean).join(", "),
      category:row.category||(Array.isArray(row.categories)?row.categories[0]:"")||"Serviços automotivos",
      open:row.open!==false,
      img:row.photo_url||"assets/vai_rodar_logo_transparent.png",
      services:Array.isArray(row.categories)?row.categories:[],
      businessType:row.business_type||"workshop",
      homeService:Boolean(row.home_service||row.at_home||row.mobile_service||normalizeText(row.service_mode||"").includes("domicilio")),
      latitude:Number.isFinite(Number(row.latitude))?Number(row.latitude):null,
      longitude:Number.isFinite(Number(row.longitude))?Number(row.longitude):null,
      schedule:row.schedule&&typeof row.schedule==="object"?row.schedule:{},
      serviceItems:(Array.isArray(row.service_items)?row.service_items:[]).map((item)=>({
        name:item.subcategory||item.name||"",
        category:item.category||"",
        desc:item.duration?`${Number(item.duration)} ${item.unit==="days"?(Number(item.duration)>1?"dias":"dia"):item.unit==="hours"?(Number(item.duration)>1?"horas":"hora"):"min"}`:"",
        price:item.price!=null?`R$ ${Number(item.price).toLocaleString("pt-BR",{minimumFractionDigits:0,maximumFractionDigits:2})}`:""
      })).filter((item)=>item.name)
    })));
```

### A3. Helper para renderizar horários reais

Buscar:

```js
function getOfficeRealServiceItems(office,category){
```

Substituir:

```js
function officeScheduleRowsHTML(office){
  const fallback='<span class="schedule-row"><b>Segunda</b><em>08:00 - 18:00</em></span><span class="schedule-row"><b>Terça</b><em>08:00 - 18:00</em></span><span class="schedule-row"><b>Quarta</b><em>08:00 - 18:00</em></span><span class="schedule-row"><b>Quinta</b><em>08:00 - 18:00</em></span><span class="schedule-row"><b>Sexta</b><em>08:00 - 18:00</em></span><span class="schedule-row"><b>Sábado</b><em>09:00 - 13:00</em></span><span class="schedule-row closed"><b>Domingo</b><em>Fechado</em></span>';
  const custom=office.schedule&&typeof office.schedule.custom==="string"?office.schedule.custom.trim():"";
  if(!custom) return fallback;
  const rows=custom.split("|").map((entry)=>{
    const splitAt=entry.indexOf(":");
    if(splitAt===-1) return null;
    const day=entry.slice(0,splitAt).trim().replace("-feira","");
    const value=entry.slice(splitAt+1).trim().replace(" às "," - ");
    if(!day||!value) return null;
    const closed=normalizeText(value).includes("fechado");
    return `<span class="schedule-row${closed?" closed":""}"><b>${day}</b><em>${value}</em></span>`;
  }).filter(Boolean);
  return rows.length?rows.join(""):fallback;
}
function getOfficeRealServiceItems(office,category){
```

### A4. Usar os horários reais no card da oficina

Buscar:

```html
        <details class="office-accordion"><summary>Horários</summary><div class="office-accordion-body"><div class="office-schedule"><span class="schedule-row"><b>Segunda</b><em>08:00 - 18:00</em></span><span class="schedule-row"><b>Terça</b><em>08:00 - 18:00</em></span><span class="schedule-row"><b>Quarta</b><em>08:00 - 18:00</em></span><span class="schedule-row"><b>Quinta</b><em>08:00 - 18:00</em></span><span class="schedule-row"><b>Sexta</b><em>08:00 - 18:00</em></span><span class="schedule-row"><b>Sábado</b><em>09:00 - 13:00</em></span><span class="schedule-row closed"><b>Domingo</b><em>Fechado</em></span></div></div></details>
```

Substituir:

```html
        <details class="office-accordion"><summary>Horários</summary><div class="office-accordion-body"><div class="office-schedule">${officeScheduleRowsHTML(office)}</div></div></details>
```

### A5. Registrar atendimento a domicílio na solicitação

Buscar:

```js
async function createServiceRequestRecord({isPart,vehicle,description,address,original,locationData={},urgency="normal",selectedBusinessIds=[]}){
```

Substituir:

```js
async function createServiceRequestRecord({isPart,vehicle,description,address,original,locationData={},urgency="normal",selectedBusinessIds=[],homeService=false}){
```

Buscar:

```js
      selected_business_ids:selectedBusinessIds,
```

Substituir:

```js
      selected_business_ids:selectedBusinessIds,
      home_service:homeService===true,
```

Nota: por enquanto nenhum fluxo passa `homeService:true`. Quando a UI de
"atendimento a domicílio" for adicionada ao fluxo de solicitação, basta
passar o parâmetro. O endereço do cliente já é gravado em `address`.

---

## PARTE B — `apps/workshop-app/index.html`

### B1. Ler `home_service` das solicitações

Buscar:

```js
    let query=sb.from("service_requests").select("id,user_id,vehicle_id,title,description,location,status,category,request_type,target_business_type,part_name,part_specs,selected_business_ids,urgency,created_at,vehicles(brand,model,year,plate,color),profiles(id,name,email),request_photos(image_url,sort_order)").order("created_at",{ascending:false}).limit(80);
```

Substituir:

```js
    let query=sb.from("service_requests").select("id,user_id,vehicle_id,title,description,location,status,category,request_type,target_business_type,part_name,part_specs,selected_business_ids,urgency,home_service,created_at,vehicles(brand,model,year,plate,color),profiles(id,name,email),request_photos(image_url,sort_order)").order("created_at",{ascending:false}).limit(80);
```

A função `isHomeServiceRequest(request)` já lê `request.home_service`;
nenhuma outra mudança é necessária para isso.

### B2. Upload real do logo (bucket `workshop-logos`)

Buscar:

```js
$("profileLogo").addEventListener("change",(event)=>previewProfileLogo(event.target.files?.[0]));
```

Substituir:

```js
$("profileLogo").addEventListener("change",async(event)=>{
  const file=event.target.files?.[0];
  if(!file) return;
  previewProfileLogo(file);
  if(!sb||!state.user?.id||!state.workshop?.id){toast("Conecte-se para salvar o logo.");return;}
  try{
    const ext=file.type==="image/png"?"png":"jpg";
    const path=`${state.user.id}/logo-${Date.now()}.${ext}`;
    const{error:uploadError}=await sb.storage.from("workshop-logos").upload(path,file,{upsert:true});
    if(uploadError) throw uploadError;
    const{data:{publicUrl}}=sb.storage.from("workshop-logos").getPublicUrl(path);
    const{error:updateError}=await sb.from("workshops").update({photo_url:publicUrl}).eq("id",state.workshop.id);
    if(updateError) throw updateError;
    state.workshop.photo_url=publicUrl;
    toast("Logo atualizado com sucesso.");
  }catch(error){
    console.error("[logo]",error.message);
    toast("Erro ao salvar o logo: "+error.message);
  }
});
```

Regras: o caminho DEVE começar com `state.user.id` (a policy de Storage
exige pasta própria). Aceitar apenas `image/png` e `image/jpeg`.

### B3. Persistir horários de atendimento

Hoje os selects de horário do painel (`.day-schedule` na seção
"Horário de atendimento") são estáticos. Implementar:

1. Ao carregar o perfil, preencher cada linha `.day-schedule` a partir de
   `state.workshop.schedule?.custom` (mesmo formato do cadastro:
   `"Segunda-feira: 08:00 às 18:00 | ... | Domingo: Fechado"`). Se um dia
   terminar em `Fechado`, marcar o checkbox `.closed-toggle input`.
2. Adicionar um botão "Salvar horários" ao final da seção que:
   - monta o texto no MESMO formato do cadastro (dias
     `Segunda-feira ... Domingo`, separador ` | `, fechado = `Dia: Fechado`,
     aberto = `Dia: HH:MM às HH:MM`);
   - preserva as outras chaves do jsonb:
     `const schedule={...(state.workshop.schedule||{}),custom:texto};`
   - executa `await sb.from("workshops").update({schedule}).eq("id",state.workshop.id)`;
   - mostra toast de sucesso/erro real (nunca sucesso falso).

### B4. Catálogo real de serviços (categorias e subcategorias)

Substituir os dados demo estáticos da seção "Categorias e servicos" por
dados reais:

1. Carregar catálogo administrado:
   `sb.from("service_categories").select("id,name,sort_order").eq("active",true).order("sort_order")`
   e
   `sb.from("service_subcategories").select("id,category_id,name,sort_order").eq("active",true).order("sort_order")`.
2. Carregar os serviços da oficina:
   `sb.from("workshop_services").select("id,category_id,subcategory_id,name,reference_price,duration,duration_unit,active").eq("workshop_id",state.workshop.id)`.
3. Renderizar as linhas `.subcategory-row` a partir de `workshop_services`
   reais (preço exibido como `R$ X`, duração como `N minutos/horas/dias`).
4. No `add-subcategory`: o select de subcategoria lista as
   `service_subcategories` ativas das categorias do taller
   (`state.workshop.services`); ao adicionar, fazer INSERT em
   `workshop_services` com:
   - `workshop_id: state.workshop.id`
   - `category_id` e `subcategory_id` da subcategoria escolhida
   - `name`: nome da subcategoria
   - `reference_price`: número extraído do campo de preço
     (`"R$ 150"` → `150`), ou null se vazio
   - `duration` + `duration_unit`: extraídos do campo de tempo
     (`"2 horas"` → `2` + `"hours"`; `"45 min"` → `45` + `"minutes"`;
     `"1 dia"` → `1` + `"days"`), ou null se vazio
5. Botão "Apagar" → DELETE do registro em `workshop_services` pelo id.
6. Erros de INSERT/DELETE devem aparecer em toast com a mensagem real.

### B5. Preview público do painel

Onde o painel monta o preview do card público (`renderProfilePreview` /
`.office-public-logo`), usar `state.workshop.photo_url` quando existir
(fallback: logo Vai Rodar) e os horários reais de
`state.workshop.schedule.custom`, para o preview refletir exatamente o
que o user app mostra.

---

## Critérios de aceite

1. Busca de oficinas mostra logo real quando existir e fallback Vai Rodar
   quando não.
2. Card da oficina mostra os horários reais do banco; fallback visual só
   quando `schedule.custom` não existir.
3. Card da oficina lista os serviços reais de `workshop_services` com
   preço e duração; sem dados demo quando a tabela estiver vazia.
4. Filtro "A domicílio" retorna só oficinas com `home_service = true`.
5. Painel do taller: logo sobe para `workshop-logos` e aparece no user
   app após recarregar; horários salvos aparecem no card público;
   subcategorias adicionadas/apagadas persistem.
6. Solicitação dirigida: taller não listado não vê a solicitação nem os
   dados do cliente (isso já é garantido pelo banco — apenas validar).
7. Falha de backend mostra erro real; nunca sucesso falso.
8. `npm run build` roda sem erros e as 5 rotas respondem.
