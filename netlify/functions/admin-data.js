const { authorize, corsHeaders, json, supabaseRequest } = require('./admin-common');

async function readMaybe(path, fallback) {
  try { return await supabaseRequest(path); }
  catch (error) {
    console.warn(`[admin-data] ${path}:`, error.message);
    return fallback;
  }
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
      reservations,
      auditLogs,
      adminUsers,
      vehicleListings,
      workshopOffers,
      profileChangeRequests,
    ] = await Promise.all([
      readMaybe('/rest/v1/admin_workshops_overview?select=*&limit=1000', []),
      readMaybe('/rest/v1/admin_dashboard_summary?select=*&limit=1', []),
      readMaybe('/rest/v1/workshop_subscriptions?select=*&limit=1000', []),
      readMaybe('/rest/v1/workshop_payments?select=*&limit=1000', []),
      readMaybe('/rest/v1/admin_top_locations_30d?select=*&limit=50', []),
      readMaybe('/rest/v1/admin_top_services_30d?select=*&limit=50', []),
      readMaybe('/rest/v1/admin_chat_usage_30d?select=*&limit=50', []),
      readMaybe('/rest/v1/analytics_events?select=*&order=created_at.desc&limit=5000', []),
      readMaybe('/rest/v1/service_requests?select=id,status&limit=5000', []),
      readMaybe('/rest/v1/reservations?select=id,status&limit=5000', []),
      readMaybe('/rest/v1/admin_audit_logs?select=*&order=created_at.desc&limit=500', []),
      readMaybe('/rest/v1/admin_users_overview?select=*&limit=5000', []),
      readMaybe('/rest/v1/vehicle_listings?select=*&order=created_at.desc&limit=1000', []),
      readMaybe('/rest/v1/workshop_offers?select=*,workshops(name)&order=created_at.desc&limit=1000', []),
      readMaybe('/rest/v1/workshop_profile_change_requests?select=*,workshops(name)&order=created_at.desc&limit=1000', []),
    ]);

    return json(200, {
      success: true,
      data: {
        workshops,
        dashboard: Array.isArray(dashboardRows) ? dashboardRows[0] || null : dashboardRows,
        subscriptions,
        payments,
        topLocations,
        topServices,
        chatUsage,
        analyticsEvents,
        serviceRequests,
        reservations,
        auditLogs,
        adminUsers,
        vehicleListings,
        workshopOffers,
        profileChangeRequests,
      },
    });
  } catch (error) {
    console.error('[admin-data]', error.message);
    return json(500, { success: false, error: error.message });
  }
};

