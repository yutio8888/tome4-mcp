"""Published Lv5 world-map source, linked to all three preceding campaigns."""
from pathlib import Path
import importlib.util
import json

spec=importlib.util.spec_from_file_location('world_campaign',Path(__file__).resolve().parents[1]/'campaign/runtime.py')
campaign=importlib.util.module_from_spec(spec);spec.loader.exec_module(campaign)
base_records=campaign.source_records
WORLD_SESSION=campaign.WORKSPACE/'tmp/tome-mcp-validation/sessions/campaign-play-v060-02'

def source_records(workspace=campaign.WORKSPACE):
    records=base_records(workspace)
    for version,key,parent in [('0.5.0','campaign-play-v050-01','campaign-play-v030-01'),
                               ('0.6.0','campaign-play-v060-02','campaign-play-v050-01')]:
        path=campaign.ADDON/f'docs/mcp-campaign-continuation-{version}.json'
        document=json.loads(path.read_text());source=records[parent]
        assert document['session']==key and document['normal_campaign'] and not document['cheat'] and not document['gameplay_fixture']
        assert document['input']['source_record']==parent
        assert Path(document['input']['source_session']).resolve()==source['session']
        assert document['input']['source_save_sha256']==source['save_sha256']
        assert all(campaign.native.sha(workspace/name)==digest for name,digest in document['sha256'].items())
        save=document['save']['sha256']
        required={'quick_hotkeys','world.teaw',*('mcp_campaign_play_01/'+name for name in ('cur.png','desc.lua','game.teag','last_log.txt'))}
        if version=='0.6.0':required.add('mcp_campaign_play_01/zone-trollmire.teaz')
        assert set(save)==required
        records[key]=dict(id=key,session=(workspace/'tmp/tome-mcp-validation/sessions'/key).resolve(),
            evidence=path.resolve(),evidence_sha256=campaign.native.sha(path),save_sha256=save,published_save_sha256=save,
            engine_sha256=document['input']['engine_sha256'],expected_state=document['last_state_before_shutdown'],
            supporting_addon_sha256=source['supporting_addon_sha256'])
    return records

campaign.source_records=source_records
CampaignRuntime=campaign.CampaignRuntime
