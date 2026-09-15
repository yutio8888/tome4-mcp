"""All published campaign sources through the Lv6 Kor'Pul2 0.6.1 save."""
from pathlib import Path
import importlib.util
import json
spec=importlib.util.spec_from_file_location('chat_world_runtime',Path(__file__).resolve().parents[1]/'worldmap/runtime.py')
world=importlib.util.module_from_spec(spec);spec.loader.exec_module(world)
campaign=world.campaign
previous=world.source_records

def source_records(workspace=campaign.WORKSPACE):
    records=previous(workspace);key='campaign-play-v061-01';path=campaign.ADDON/'docs/mcp-campaign-continuation-0.6.1.json'
    document=json.loads(path.read_text());source=records['campaign-play-v060-02']
    assert document['session']==key and document['normal_campaign'] and not document['cheat'] and not document['gameplay_fixture']
    assert document['input']['source_record']==source['id'] and document['input']['source_save_sha256']==source['save_sha256']
    assert all(campaign.native.sha(workspace/name)==digest for name,digest in document['sha256'].items())
    save=document['save']['sha256']
    records[key]=dict(id=key,session=(workspace/'tmp/tome-mcp-validation/sessions'/key).resolve(),
        evidence=path.resolve(),evidence_sha256=campaign.native.sha(path),save_sha256=save,published_save_sha256=save,
        engine_sha256=document['input']['engine_sha256'],expected_state=document['last_state_before_shutdown'],
        supporting_addon_sha256=source['supporting_addon_sha256'])
    return records
campaign.source_records=source_records
CampaignRuntime=campaign.CampaignRuntime
