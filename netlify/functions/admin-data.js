const { authorize, corsHeaders, json, supabaseRequest } = require('./admin-common');

async function readMaybe(path, fallback) {
  try { return await supabaseRequest(path); }
  catch (error) {
    console.warn(`[admin-data] ${path}:`, error.message);
    return fallback;
  }
}

async function readRequired(path, dataset) {
  try { return await supabaseRequest(path); }
  catch (error) {
    throw new Error(`${dataset}: ${error.message}`);
  }
}

function asList(value) {
  if (Array.isArray(value)) return value;
  if (Array.isArray(value?.data)) return value.data;
  return [];
}

exports.handler = async (event) => {
  if (event.httpMethod === 'OPTIONS') return { statusCode: 200, headers: corsHeaders, body: '' };
  if (event.httpMethod !== 'GET') return json(405, { success: false, error: 'Method not allowed' });

  try {
    if (!authorize(event)) return json(401, { success: false, error: 'Senha admin invalida.' });

    const [
      workshops,
      dashboardRows,
      subscriptions,
      payments,
      topLocations,
      topServices,
      chatUsage,
      analyticsEvents,
      serviceRequests,
      proposals,
      requestLifecycle,
      requestEvents,
      proposalMetrics,
      proposalSummaryRows,
      reservations,
      auditLogs,
      adminUsers,
      vehicleListings,
      workshopOffers,
      profileChangeRequests,
      serviceCategories,
      serviceSubcategories,
      workshopServices,
      conversations,
      messages,
      vehicles,
      plateLookups,
      crmContacts,
      crmMessages,
      crmTemplates,
      plansCatalog,
    ] = await Promise.all([
      readRequired('/rest/v1/admin_workshops_overview?select=*&limit=1000', 'Oficinas'),
      readMaybe('/rest/v1/admin_dashboard_summary?select=*&limit=1', []),
      readMaybe('/rest/v1/workshop_subscriptions?select=*&limit=1000', []),
      readMaybe('/rest/v1/workshop_payments?select=*&limit=1000', []),
      readMaybe('/rest/v1/admin_top_locations_30d?select=*&limit=50', []),
      readMaybe('/rest/v1/admin_top_services_30d?select=*&limit=50', []),
      readMaybe('/rest/v1/admin_chat_usage_30d?select=*&limit=50', []),
      readMaybe('/rest/v1/analytics_events?select=*&order=created_at.desc&limit=5000', []),
      readRequired('/rest/v1/service_requests?select=*&order=created_at.desc&limit=1000', 'Solicitacoes'),
      readMaybe('/rest/v1/proposals?select=*&order=created_at.desc&limit=5000', []),
      readMaybe('/rest/v1/admin_request_lifecycle?select=*&order=created_at.desc&limit=1000', []),
      readMaybe('/rest/v1/request_lifecycle_events?select=*&order=created_at.desc&limit=5000', []),
      readMaybe('/rest/v1/admin_proposal_metrics_30d?select=*&order=total_requests.desc&limit=200', []),
      readMaybe('/rest/v1/admin_proposal_summary_30d?select=*&limit=1', []),
      readRequired('/rest/v1/reservations?select=*&order=scheduled_at.desc&limit=1000', 'Reservas'),
      readMaybe('/rest/v1/admin_audit_logs?select=*&order=created_at.desc&limit=500', []),
      readRequired('/rest/v1/admin_users_overview?select=*&limit=5000', 'Usuarios'),
      readMaybe('/rest/v1/vehicle_listings?select=*&order=created_at.desc&limit=1000', []),
      readMaybe('/rest/v1/workshop_offers?select=*,workshops(name)&order=created_at.desc&limit=1000', []),
      readMaybe('/rest/v1/workshop_profile_change_requests?select=*,workshops(name)&order=created_at.desc&limit=1000', []),
      readRequired('/rest/v1/service_categories?select=*&order=sort_order.asc&limit=200', 'Catalogo de servicos'),
      readMaybe('/rest/v1/service_subcategories?select=*&order=sort_order.asc&limit=1000', []),
      readMaybe('/rest/v1/workshop_services?select=*,workshops(name)&order=created_at.desc&limit=3000', []),
      readMaybe('/rest/v1/conversations?select=*,profiles(name,email),workshops(name)&order=created_at.desc&limit=1000', []),
      readMaybe('/rest/v1/messages?select=*&order=created_at.desc&limit=3000', []),
      readMaybe('/rest/v1/vehicles?select=*&order=created_at.desc&limit=5000', []),
      readMaybe('/rest/v1/plate_lookups?select=*&limit=5000', []),
      readMaybe('/rest/v1/crm_contacts?select=*,workshops(name)&order=last_message_at.desc.nullslast&limit=2000', []),
      readMaybe('/rest/v1/crm_messages?select=*&order=created_at.desc&limit=3000', []),
      readMaybe('/rest/v1/crm_templates?select=*&order=created_at.desc&limit=200', []),
      readMaybe('/rest/v1/plans?select=*&order=sort_order.asc&limit=20', []),
    ]);

    const workshopRows = asList(workshops);
    const userRows = asList(adminUsers);
    const vehicleRows = asList(vehicles);
    const proposalRows = asList(proposals);
    const userFor = (id) => userRows.find((item) => String(item.id || item.user_id) === String(id)) || null;
    const workshopFor = (id) => workshopRows.find((item) => String(item.id) === String(id)) || null;
    const vehicleFor = (id) => vehicleRows.find((item) => String(item.id) === String(id)) || null;
    const hydratedRequests = asList(serviceRequests).map((request) => ({
      ...request,
      profiles: userFor(request.user_id),
      vehicles: vehicleFor(request.vehicle_id),
      proposals: proposalRows
        .filter((proposal) => String(proposal.request_id) === String(request.id))
        .map((proposal) => ({ ...proposal, workshops: workshopFor(proposal.workshop_id) })),
    }));
    const hydratedReservations = asList(reservations).map((reservation) => ({
      ...reservation,
      profiles: userFor(reservation.user_id),
      workshops: workshopFor(reservation.workshop_id),
    }));

    return json(200, {
      success: true,
      data: {
        workshops: workshopRows,
        dashboard: Array.isArray(dashboardRows) ? dashboardRows[0] || null : dashboardRows,
        dashboardSummary: asList(dashboardRows),
        subscriptions: asList(subscriptions),
        payments: asList(payments),
        topLocations: asList(topLocations),
        topServices: asList(topServices),
        chatUsage: asList(chatUsage),
        analyticsEvents: asList(analyticsEvents),
        serviceRequests: hydratedRequests,
        requestLifecycle: asList(requestLifecycle),
        requestEvents: asList(requestEvents),
        proposalMetrics: asList(proposalMetrics),
        proposalSummary: Array.isArray(proposalSummaryRows) ? proposalSummaryRows[0] || null : proposalSummaryRows,
        reservations: hydratedReservations,
        auditLogs: asList(auditLogs),
        adminUsers: userRows,
        vehicleListings: asList(vehicleListings),
        workshopOffers: asList(workshopOffers),
        profileChangeRequests: asList(profileChangeRequests),
        serviceCategories: asList(serviceCategories),
        serviceSubcategories: asList(serviceSubcategories),
        workshopServices: asList(workshopServices),
        conversations: asList(conversations),
        messages: asList(messages),
        vehicles: vehicleRows,
        plateLookups: asList(plateLookups),
        crmContacts: asList(crmContacts),
        crmMessages: asList(crmMessages),
        crmTemplates: asList(crmTemplates),
        plansCatalog: asList(plansCatalog),
      },
    });
  } catch (error) {
    console.error('[admin-data]', error.message);
    return json(500, { success: false, error: error.message });
  }
};

