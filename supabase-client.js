/* ──────────────────────────────────────────────────────────────────────
   ei-tools — shared Supabase client + auth helpers.

   Usage on any page:
     <script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
     <script src="supabase-client.js"></script>

   Then call window.eitools.sb / requireAuth / logActivity / signOut.

   Note: the publishable key below is intentionally public. RLS policies
   and Supabase Auth gate everything. Don't put the secret key here.
   ────────────────────────────────────────────────────────────────────── */

(function(){
  if (window.eitools && window.eitools.sb) return; // idempotent

  var SUPABASE_URL = 'https://aicrefpmzqkmoksdpqcj.supabase.co';
  var SUPABASE_KEY = 'sb_publishable_t_alUOzCPbEgFHfLRaa6xw_1_mc35wR';

  if (typeof supabase === 'undefined' || typeof supabase.createClient !== 'function') {
    console.error('[ei-tools] supabase-js must be loaded before supabase-client.js');
    return;
  }

  var sb = supabase.createClient(SUPABASE_URL, SUPABASE_KEY, {
    auth: {
      persistSession: true,
      autoRefreshToken: true,
      detectSessionInUrl: true,
      flowType: 'pkce'
    }
  });

  window.eitools = {
    sb: sb,
    SUPABASE_URL: SUPABASE_URL,

    /**
     * Auth gate. Call near the top of any page that requires login.
     * Returns the session, or redirects to login.html and resolves to null.
     *
     *   const session = await window.eitools.requireAuth();
     *   if (!session) return;
     */
    requireAuth: async function(){
      var res = await sb.auth.getSession();
      var session = res && res.data && res.data.session;
      if (!session) {
        window.location.href = 'login.html';
        return null;
      }
      return session;
    },

    /** Returns the current user (or null). */
    getUser: async function(){
      var res = await sb.auth.getUser();
      return (res && res.data && res.data.user) || null;
    },

    /**
     * Best-effort activity log. Non-blocking; swallows errors.
     *   window.eitools.logActivity('hub', 'pageview');
     */
    logActivity: async function(page, type){
      try {
        var u = await window.eitools.getUser();
        if (!u) return;
        await sb.from('activity').insert({
          username: u.email,
          page: page,
          type: type || 'pageview'
        });
      } catch (e) { /* swallow */ }
    },

    /** Sign out and bounce to login. */
    signOut: async function(){
      try { await sb.auth.signOut(); } catch (e) {}
      window.location.href = 'login.html';
    }
  };
})();
