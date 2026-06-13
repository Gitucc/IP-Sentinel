// IP-Sentinel Anonymous Telemetry API
// 部署环境: Cloudflare Workers + KV
// 隐私声明: 本系统仅执行原子累加计数。完全匿名统计，不采集、不存储用户的 IP 地址、请求头、Token 或任何系统特征参数。

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname;

    const corsHeaders = {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "GET",
    };

    async function incrementCounter(key) {
      let count = await env.SENTINEL_KV.get(key);
      count = count ? parseInt(count) + 1 : 1;
      await env.SENTINEL_KV.put(key, count.toString());
      return count;
    }

    async function getCounter(key) {
      let count = await env.SENTINEL_KV.get(key);
      return count ? parseInt(count) : 0;
    }

    try {
      if (path === '/ping/agent') {
        const count = await incrementCounter('agent_count');
        return new Response(count.toString(), { headers: corsHeaders });
      }
      
      if (path === '/ping/master') {
        const count = await incrementCounter('master_count');
        return new Response(count.toString(), { headers: corsHeaders });
      }

      if (path === '/stats/agent') {
        const count = await getCounter('agent_count');
        const shield = {
          schemaVersion: 1,
          label: "Agent Nodes",
          message: count.toString(),
          color: "blue"
        };
        return new Response(JSON.stringify(shield), { 
          headers: { ...corsHeaders, "Content-Type": "application/json" } 
        });
      }

      if (path === '/stats/master') {
        const count = await getCounter('master_count');
        const shield = {
          schemaVersion: 1,
          label: "Master Commands",
          message: count.toString(),
          color: "orange"
        };
        return new Response(JSON.stringify(shield), { 
          headers: { ...corsHeaders, "Content-Type": "application/json" } 
        });
      }

      return new Response("IP-Sentinel Anonymous Telemetry API (No IP Logged, Transparent)", { status: 200 });
    } catch (err) {
      return new Response("Error", { status: 500 });
    }
  }
};
