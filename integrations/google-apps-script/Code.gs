const SPREADSHEET_ID = "1YEjybrG16hLzfVm0-Z76PLcMJBYk9Fa9fQyIDwuPZ5o";

function doGet(e) {
  const action = e && e.parameter && e.parameter.action;

  if (action === "getTotalCadastrosJsonp") {
    return jsonpResponse(e, { ok: true, total: getTotalCadastros() });
  }

  if (action === "debugJsonp") {
    return jsonpResponse(e, debugDestination());
  }

  if (action === "addWorkshopJsonp") {
    let workshop = {};
    try {
      workshop = JSON.parse((e.parameter && e.parameter.payload) || "{}");
    } catch (error) {
      return jsonpResponse(e, { ok: false, error: "Payload inválido" });
    }
    return jsonpResponse(e, addWorkshop(workshop));
  }

  return HtmlService
    .createHtmlOutputFromFile("Public")
    .setTitle("Vai Rodar - Cadastro de Oficinas")
    .addMetaTag("viewport", "width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no");
}

function debugDestination() {
  const spreadsheet = SpreadsheetApp.openById(SPREADSHEET_ID);
  const sheet = getWorkshopSheet();
  return {
    ok: true,
    spreadsheetId: spreadsheet.getId(),
    spreadsheetName: spreadsheet.getName(),
    spreadsheetUrl: spreadsheet.getUrl(),
    sheetName: sheet.getName(),
    total: getTotalCadastros()
  };
}

function jsonpResponse(e, data) {
  const callback = sanitizeCallback_(e && e.parameter && e.parameter.callback);
  return ContentService
    .createTextOutput(callback + "(" + JSON.stringify(data || {}) + ");")
    .setMimeType(ContentService.MimeType.JAVASCRIPT);
}

function sanitizeCallback_(callback) {
  const value = String(callback || "callback");
  return /^[A-Za-z_$][0-9A-Za-z_$]*(\.[A-Za-z_$][0-9A-Za-z_$]*)*$/.test(value)
    ? value
    : "callback";
}

function api(request) {
  try {
    if (!request || !request.action) return { ok: false, error: "Ação não informada" };
    if (request.action === "addWorkshop") return addWorkshop(request.workshop || {});
    if (request.action === "getWorkshops") return { ok: true, workshops: getWorkshops() };
    if (request.action === "getTotalCadastros") return { ok: true, total: getTotalCadastros() };
    return { ok: false, error: "Ação não suportada" };
  } catch (error) {
    return { ok: false, error: String(error.message || error) };
  }
}

function addWorkshop(workshop) {
  if (!workshop.nomeNegocio || !workshop.responsavel || !workshop.whatsapp || !workshop.cep || !workshop.estado || !workshop.cidade || !workshop.bairro || !workshop.endereco || !workshop.numero || !workshop.servicos || !workshop.horarioPersonalizado) {
    return { ok: false, error: "Faltam dados obrigatórios" };
  }
  if (!workshop.semCnpj && !/^\d{2}\.\d{3}\.\d{3}\/\d{4}-\d{2}$/.test(String(workshop.cnpj || ""))) {
    return { ok: false, error: "CNPJ inválido" };
  }
  if (!/^\+55 \d{2} \d{5}-\d{4}$/.test(String(workshop.whatsapp || ""))) {
    return { ok: false, error: "WhatsApp inválido" };
  }

  const headers = getWorkshopHeaders();
  const sheet = getWorkshopSheet();
  const id = "VR-" + Utilities.getUuid();
  const row = {
    "ID": id,
    "Criado Em": new Date(),
    "Status": "Novo",
    "Nome do Negócio": workshop.nomeNegocio,
    "CNPJ": workshop.semCnpj ? "" : workshop.cnpj,
    "Sem CNPJ": workshop.semCnpj ? "Sim" : "Não",
    "Responsável": workshop.responsavel,
    "WhatsApp": workshop.whatsapp,
    "E-mail": workshop.email || "",
    "CEP": workshop.cep,
    "Estado": workshop.estado,
    "Cidade": workshop.cidade,
    "Bairro": workshop.bairro,
    "Endereço da Oficina": workshop.endereco,
    "Número": workshop.numero,
    "Complemento": workshop.complemento || "",
    "Forma de Atendimento": workshop.formaAtendimento || "Na oficina",
    "Serviços": workshop.servicos,
    "Dias de Atendimento": workshop.diasAtendimento || "Personalizado",
    "Horário de Abertura": "",
    "Horário de Fechamento": "",
    "Horário Personalizado": workshop.horarioPersonalizado || ""
  };
  sheet.appendRow(headers.map(function(header) { return row[header]; }));
  return { ok: true, id: id, total: getTotalCadastros() };
}

function getTotalCadastros() {
  const sheet = getWorkshopSheet();
  const values = sheet.getDataRange().getValues();
  let total = 0;
  for (let i = 1; i < values.length; i++) {
    if (values[i].join("").trim() !== "") total++;
  }
  return total;
}

function getWorkshops() {
  const sheet = getWorkshopSheet();
  const values = sheet.getDataRange().getValues();
  if (values.length < 2) return [];
  const headers = values[0];
  const rows = [];
  for (let i = 1; i < values.length; i++) {
    if (!values[i][0]) continue;
    const item = {};
    for (let j = 0; j < headers.length; j++) {
      const value = values[i][j];
      item[headers[j]] = value instanceof Date
        ? Utilities.formatDate(value, Session.getScriptTimeZone(), "yyyy-MM-dd'T'HH:mm:ss")
        : value;
    }
    rows.push(item);
  }
  return rows;
}

function getWorkshopSheet() {
  const headers = getWorkshopHeaders();
  const spreadsheet = SpreadsheetApp.openById(SPREADSHEET_ID);
  const sheetName = "Talleres";
  const sheet = spreadsheet.getSheetByName(sheetName) || spreadsheet.insertSheet(sheetName);
  const currentHeaders = sheet.getRange(1, 1, 1, headers.length).getValues()[0];
  if (currentHeaders.join("|") !== headers.join("|")) {
    sheet.getRange(1, 1, 1, headers.length).setValues([headers]);
    sheet.setFrozenRows(1);
  }
  return sheet;
}

function getWorkshopHeaders() {
  return [
    "ID",
    "Criado Em",
    "Status",
    "Nome do Negócio",
    "CNPJ",
    "Sem CNPJ",
    "Responsável",
    "WhatsApp",
    "E-mail",
    "CEP",
    "Estado",
    "Cidade",
    "Bairro",
    "Endereço da Oficina",
    "Número",
    "Complemento",
    "Forma de Atendimento",
    "Serviços",
    "Dias de Atendimento",
    "Horário de Abertura",
    "Horário de Fechamento",
    "Horário Personalizado"
  ];
}
