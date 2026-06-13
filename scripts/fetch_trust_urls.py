import urllib.request
import xml.etree.ElementTree as ET
import os
import json
import random
import re

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(SCRIPT_DIR)
REGIONS_DIR = os.path.join(PROJECT_ROOT, "data", "regions")

USER_AGENTS = [
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/133.0.0.0 Safari/537.36',
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/133.0.0.0 Safari/537.36 Edg/133.0.0.0',
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:135.0) Gecko/20100101 Firefox/135.0',
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/133.0.0.0 Safari/537.36',
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/618.1.15 (KHTML, like Gecko) Version/18.3 Safari/618.1.15',
    'Mozilla/5.0 (iPhone; CPU iPhone OS 18_3_1 like Mac OS X) AppleWebKit/618.1.15 (KHTML, like Gecko) Version/18.3 Mobile/15E148 Safari/604.1',
    'Mozilla/5.0 (Linux; Android 15; Pixel 9 Pro) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/133.0.0.0 Mobile Safari/537.36'
]

def is_dual_stack_safe(url):
    DUAL_STACK_SAFE_DOMAINS = [
        "google.com", "wikipedia.org", "apple.com", "microsoft.com", 
        "wikimedia.org", "blogspot.com", "yahoo.com"
    ]
    return any(domain in url for domain in DUAL_STACK_SAFE_DOMAINS)

def fetch_rss_links(lang_params, region_name, max_items=25):
    url = f"https://news.google.com/rss?{lang_params}"
    links = []
    
    try:
        dynamic_headers = {'User-Agent': random.choice(USER_AGENTS)}
        req = urllib.request.Request(url, headers=dynamic_headers)
        with urllib.request.urlopen(req, timeout=10) as response:
            xml_data = response.read()
            root = ET.fromstring(xml_data)
            for item in root.findall('.//item'):
                link = item.find('link')
                if link is not None and link.text:
                    clean_link = link.text.strip()
                    if clean_link.startswith('http') and is_dual_stack_safe(clean_link):
                        links.append(clean_link)
    except Exception as e:
        print(f"[{region_name}] RSS 抓取异常 ({url}): {e}")
        
    unique_links = list(set(links))
    random.shuffle(unique_links)
    return unique_links[:max_items]

def process_json_file(file_path):
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            data = json.load(f)
            
        trust_mod = data.get("trust_module", {})
        google_mod = data.get("google_module", {})
        region_name = data.get("region_name", "Unknown")
        
        if not trust_mod or not google_mod:
            return
            
        lang_params = google_mod.get("lang_params", "hl=en-US&gl=US")
        
        hl_match = re.search(r'hl=([a-zA-Z]+)', lang_params)
        lang_prefix = hl_match.group(1).split('-')[0].lower() if hl_match else 'en'
        
        static_urls = trust_mod.get("static_urls", [])
        
        if len(static_urls) < 5:
            static_urls += [f"https://{lang_prefix}.wikipedia.org/wiki/Special:Random", "https://www.apple.com/", "https://www.microsoft.com/"]
        random.shuffle(static_urls)
        final_static = list(set(static_urls))[:5]
        
        final_news = fetch_rss_links(lang_params, region_name, max_items=25)
        
        combined_urls = list(set(final_static + final_news))
        
        while len(combined_urls) < 30:
            combined_urls.append(f"https://{lang_prefix}.wikipedia.org/wiki/Special:Random?r={random.randint(1,100000)}")
            combined_urls = list(set(combined_urls))
            
        final_white_list = combined_urls[:30]
        random.shuffle(final_white_list)
        
        trust_mod["white_urls"] = final_white_list
        data["trust_module"] = trust_mod
        
        with open(file_path, 'w', encoding='utf-8') as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
            
        print(f"[信用融合] {os.path.basename(file_path)} (语系: {lang_prefix}): 固化基石 {len(final_static)} 条 + 活体新闻 {len(final_news)} 条 = 共 {len(final_white_list)} 条")
        
    except Exception as e:
        print(f"[处理失败] {file_path}: {e}")

if __name__ == '__main__':
    print("启动新闻流融合引擎...")
    for root_dir, _, files in os.walk(REGIONS_DIR):
        for file in files:
            if file.endswith(".json"):
                file_path = os.path.join(root_dir, file)
                process_json_file(file_path)
    print("融合引擎执行完毕。")