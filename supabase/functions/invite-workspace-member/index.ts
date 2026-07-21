import { createClient } from 'npm:@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function json(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json; charset=utf-8' },
  });
}

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (request.method !== 'POST') return json(405, { error: 'Yalnızca POST isteği kabul edilir.' });

  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY');
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  const siteUrl = Deno.env.get('SITE_URL');
  const authorization = request.headers.get('Authorization');

  if (!supabaseUrl || !anonKey || !serviceRoleKey || !authorization) {
    return json(500, { error: 'Sunucu davet ayarları eksik.' });
  }

  const callerClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authorization } },
  });
  const adminClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  const { data: userData, error: userError } = await callerClient.auth.getUser();
  if (userError || !userData.user) return json(401, { error: 'Oturum doğrulanamadı.' });

  let body: { organizationId?: string; email?: string; displayName?: string };
  try {
    body = await request.json();
  } catch {
    return json(400, { error: 'Geçersiz istek.' });
  }

  const organizationId = String(body.organizationId || '').trim();
  const email = String(body.email || '').trim().toLowerCase();
  const displayName = String(body.displayName || '').trim();
  if (!organizationId || !/^\S+@\S+\.\S+$/.test(email)) {
    return json(400, { error: 'Şirket hesabı ve geçerli e-posta zorunludur.' });
  }

  const { data: ownerMembership } = await adminClient
    .from('organization_members')
    .select('id')
    .eq('organization_id', organizationId)
    .eq('user_id', userData.user.id)
    .eq('role', 'owner')
    .eq('status', 'active')
    .maybeSingle();
  if (!ownerMembership) return json(403, { error: 'Yalnızca şirket sahibi çalışan davet edebilir.' });

  const { data: subscription } = await adminClient
    .from('organization_subscriptions')
    .select('plan,status')
    .eq('organization_id', organizationId)
    .maybeSingle();
  if (subscription?.plan !== 'company' || subscription?.status !== 'active') {
    return json(403, { error: 'Çalışan hesabı yalnızca aktif Şirket planında kullanılabilir.' });
  }

  const { count } = await adminClient
    .from('organization_members')
    .select('id', { count: 'exact', head: true })
    .eq('organization_id', organizationId)
    .neq('status', 'suspended');
  if ((count || 0) >= 3) return json(409, { error: 'Şirket planındaki 3 giriş hesabı sınırına ulaşıldı.' });

  const redirectTo = siteUrl ? `${siteUrl.replace(/\/$/, '')}/` : undefined;
  const { data: invited, error: inviteError } = await adminClient.auth.admin.inviteUserByEmail(email, {
    redirectTo,
    data: { organization_id: organizationId, role: 'employee', display_name: displayName },
  });
  if (inviteError || !invited.user) {
    return json(400, { error: inviteError?.message || 'Davet gönderilemedi.' });
  }

  const { error: memberError } = await adminClient.from('organization_members').insert({
    organization_id: organizationId,
    user_id: invited.user.id,
    email,
    display_name: displayName || null,
    role: 'employee',
    status: 'invited',
    invited_by: userData.user.id,
  });
  if (memberError) return json(400, { error: memberError.message });

  return json(200, {
    ok: true,
    member: { userId: invited.user.id, email, displayName, role: 'employee', status: 'invited' },
  });
});
