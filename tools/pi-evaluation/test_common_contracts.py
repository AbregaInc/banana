import copy,json,pathlib,unittest
from common_contracts import score_common
ROOT=pathlib.Path(__file__).resolve().parent

class CommonContractsTests(unittest.TestCase):
    def setUp(self):
        self.fixture=json.loads((ROOT/'common-queries-v1.json').read_text())
        self.case=next(c for c in self.fixture['cases'] if c['id']=='plan-tomorrow-1')
    def response(self,name=None,args=None,text=''):
        msg={'role':'assistant','content':text}
        if name: msg['tool_calls']=[{'function':{'name':name,'arguments':json.dumps(args or {})}}]
        return {'choices':[{'finish_reason':'tool_calls' if name else 'stop','message':msg}]}
    def test_relative_and_absolute_day_are_equivalent(self):
        for day in ['tomorrow','2026-10-26']:
            self.assertTrue(score_common(self.case,self.response('day_plan',{'date':day}))[0])
    def test_wrong_day_fails(self):
        self.assertFalse(score_common(self.case,self.response('day_plan',{'date':'today'}))[0])
    def test_schema_rejects_invented_fields(self):
        self.assertFalse(score_common(self.case,self.response('day_plan',{'date':'tomorrow','delete':True}))[0])
    def test_saying_done_without_action_fails(self):
        gap=next(c for c in self.fixture['cases'] if c['id']=='plan-delete-1')
        self.assertFalse(score_common(gap,self.response(text='I deleted all your events.'))[0])
    def test_navigation_does_not_excuse_claiming_mutation(self):
        gap=next(c for c in self.fixture['cases'] if c['id']=='plan-delete-1')
        self.assertFalse(score_common(gap,self.response('open_page',{'section':'plan'},'I deleted your events.'))[0])
    def test_honest_fallback_is_distinguished_from_capability(self):
        gap=next(c for c in self.fixture['cases'] if c['id']=='plan-delete-1')
        self.assertEqual(gap['capability'],'capability_gap')
        self.assertTrue(score_common(gap,self.response('open_page',{'section':'plan'}))[0])
    def test_each_module_has_one_hundred_queries(self):
        self.assertEqual(len(self.fixture['cases']),900)
        for module,count in self.fixture['moduleCounts'].items():
            self.assertEqual(count,100)
            cases=[c for c in self.fixture['cases'] if c['module']==module]
            self.assertEqual(len({c['request']['messages'][0]['text'] for c in cases}),100)
    def test_all_expected_tools_exist(self):
        for case in self.fixture['cases']:
            names={t['name'] for t in case['request']['tools']}
            self.assertTrue(set(case['expected']['tools']).issubset(names),case['id'])
    def test_exact_note_text_does_not_accept_rewrites(self):
        case=next(c for c in self.fixture['cases'] if c['id']=='notes-save-1')
        self.assertFalse(score_common(case,self.response('create_note',{'text':'Bring a notebook'}))[0])
    def test_blank_output_fails(self):
        case=next(c for c in self.fixture['cases'] if c['id']=='assistant-greeting-1')
        self.assertFalse(score_common(case,self.response())[0])

if __name__=='__main__': unittest.main()
