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
    ] = await Promise.all([
      readRequired('/rest/v1/admin_workshops_overview?select=*&limit=1000', 'Oficinas'),
      readMaybe('/rest/v1/admin_dashboard_summary?select=*&limit=1', []),
      readMaybe('/rest/v1/workshop_subscriptions?select=*&limit=1000', []),
      readMaybe('/rest/v1/workshop_payments?select=*&limit=1000', []),
      readMaybe('/rest/v1/admin_top_locations_30d?select=*&limit=50', []),
      readMaybe('/rest/v1/admin_top_services_30d?select=*&limit=50', []),
      readMaybe('/rest/v1/admin_chat_usage_30d?select=*&limit=50', []),
      readMaybe('/rest/v1/analytics_events?select=*&order=created_at.desc&limit=5000', []),
      readMaybe('/rest/v1/service_requests?select=*,profiles(id,name,email,phone),vehicles(brand,model,year,plate),proposals(*,workshops(id,name,address,city,state))&order=created_at.desc&limit=1000', []),
      readMaybe('/rest/v1/admin_request_lifecycle?select=*&order=created_at.desc&limit=1000', []),
      readMaybe('/rest/v1/request_lifecycle_events?select=*&order=created_at.desc&limit=5000', []),
      readMaybe('/rest/v1/admin_proposal_metrics_30d?select=*&order=total_requests.desc&limit=200', []),
      readMaybe('/rest/v1/admin_proposal_summary_30d?select=*&limit=1', []),
      readMaybe('/rest/v1/reservations?select=*,profiles(name,email),workshops(name)&order=scheduled_at.desc&limit=1000', []),
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
    ]);

    return json(200, {
      success: true,
      data: {
        workshops: asList(workshops),
        dashboard: Array.isArray(dashboardRows) ? dashboardRows[0] || null : dashboardRows,
        dashboardSummary: asList(dashboardRows),
        subscriptions: asList(subscriptions),
        payments: asList(payments),
        topLocations: asList(topLocations),
        topServices: asList(topServices),
        chatUsage: asList(chatUsage),
        analyticsEvents: asList(analyticsEvents),
        serviceRequests: asList(serviceRequests),
        requestLifecycle: asList(requestLifecycle),
        requestEvents: asList(requestEvents),
        proposalMetrics: asList(proposalMetrics),
        proposalSummary: Array.isArray(proposalSummaryRows) ? proposalSummaryRows[0] || null : proposalSummaryRows,
        reservations: asList(reservations),
        auditLogs: asList(auditLogs),
        adminUsers: asList(adminUsers),
        vehicleListings: asList(vehicleListings),
        workshopOffers: asList(workshopOffers),
        profileChangeRequests: asList(profileChangeRequests),
        serviceCategories: asList(serviceCategories),
        serviceSubcategories: asList(serviceSubcategories),
        workshopServices: asList(workshopServices),
        conversations: asList(conversations),
        messages: asList(messages),
        vehicles: asList(vehicles),
        plateLookups: asList(plateLookups),
      },
    });
  } catch (error) {
    console.error('[admin-data]', error.message);
    return json(500, { success: false, error: error.message });
  }
};

