# Vai Rodar - Deploys

Este repositorio tiene mas de un frontend. Para evitar confusiones, estas son las carpetas oficiales:

## 1. App usuario

- Carpeta oficial: `frontend-app`
- Archivo principal: `frontend-app/index.html`
- Netlify: sitio principal de la app Vai Rodar
- Publish directory en Netlify: `frontend-app`
- Build command: vacio

Aqui viven tambien la PWA:

- `frontend-app/manifest.json`
- `frontend-app/service-worker.js`
- `frontend-app/assets/icon-*.png`

## 2. Registro de talleres

- Carpeta oficial: `frontend-workshop-register`
- Archivo principal: `frontend-workshop-register/index.html`
- Netlify: link separado para cadastro de oficinas
- Publish directory en Netlify: `frontend-workshop-register`
- Build command: vacio

Este es el unico HTML que se debe subir o editar para el registro publico de talleres.

## 3. Prototipos

- Carpeta: `prototypes`
- Uso: historico, pruebas visuales y referencias
- No usar como publish directory de Netlify
- No editar como fuente oficial salvo que se quiera guardar una prueba puntual

## 4. Backoffice futuro

- Backoffice talleres: `frontend-backoffice-workshop`
- Backoffice admin Vai Rodar: `frontend-backoffice-admin`
- Estado actual: carpetas preparadas, sin interfaz oficial todavia

## 5. Backend

- Apps Script: `backend/google-apps-script/Code.gs`
- Supabase futuro: `backend/src`

## Regla de trabajo

Antes de editar, confirmar que se esta trabajando en la carpeta correcta:

- App usuario: `frontend-app`
- Cadastro oficinas: `frontend-workshop-register`
- Backoffice talleres: `frontend-backoffice-workshop`
- Backoffice admin: `frontend-backoffice-admin`
