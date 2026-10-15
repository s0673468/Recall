"""Closed rendered-frame receipt controls; no SDK, emulator or ADB calls."""
import importlib.util
from pathlib import Path
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'measure_android_cold_start.py'
spec = importlib.util.spec_from_file_location('rendered_frame_consumer', SCRIPT)
consumer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(consumer)
COMMIT = 'a'*40
PID = 55


def events():
    common = {'schema':consumer.SCHEMA,'source_commit':COMMIT,'pid':PID,
              'build_mode':'debug','environment':'isolated-android-emulator'}
    timing = {key:1 for key in consumer.TIMINGS}
    timing.update(dart_main_root_ready=2,rating_to_next=10,rating_to_next_painted_frame=20)
    integrity = {'cards_loaded':20,'pending_after_rating':1,'next_card_id':2,'http_requests':4,
                 'native_preferences':True,'initial_card_painted':True,
                 'next_card_painted':True,'painted_next_card_id':2}
    return {'first_frame':(1,{**common,'phase':'first_frame','dart_main_elapsed_us':1}),
            'root_ready':(2,{**common,'phase':'root_ready','dart_main_elapsed_us':2}),
            'done':(3,{**common,'phase':'done','timing_us':timing,'integrity':integrity})}


class RenderedFrameContractTests(unittest.TestCase):
    def test_one_rating_and_painted_card2_keep_existing_measurements_distinct(self):
        result=consumer.validate_events(events(),PID,COMMIT)
        self.assertEqual(result['timing_us']['rating_to_next'],10)
        self.assertEqual(result['timing_us']['rating_to_next_painted_frame'],20)
        self.assertEqual(result['integrity']['pending_after_rating'],1)

    def test_status_only_or_nonadvanced_identity_is_refused(self):
        for change in [{'initial_card_painted':False},{'next_card_painted':False},
                       {'painted_next_card_id':1},{'next_card_id':1}]:
            with self.subTest(change=change):
                value=events();value['done'][1]['integrity'].update(change)
                with self.assertRaises(consumer.Refused):consumer.validate_events(value,PID,COMMIT)

    def test_missing_or_additional_frame_fields_are_refused(self):
        for field in ['initial_card_painted','next_card_painted','painted_next_card_id']:
            value=events();del value['done'][1]['integrity'][field]
            with self.assertRaises(consumer.Refused):consumer.validate_events(value,PID,COMMIT)
        value=events();del value['done'][1]['timing_us']['rating_to_next_painted_frame']
        with self.assertRaises(consumer.Refused):consumer.validate_events(value,PID,COMMIT)
        for section in ['timing_us','integrity']:
            value=events();value['done'][1][section]['untrusted_detail']='invented-not-retained'
            with self.assertRaises(consumer.Refused):consumer.validate_events(value,PID,COMMIT)

    def test_paint_clock_cannot_precede_controller_ack_or_be_boolean(self):
        for value in [9,True,-1]:
            candidate=events();candidate['done'][1]['timing_us']['rating_to_next_painted_frame']=value
            with self.assertRaises(consumer.Refused):consumer.validate_events(candidate,PID,COMMIT)

    def test_frame_flags_require_actual_boolean_types_and_exact_one_event(self):
        for key,value in [('initial_card_painted',1),('next_card_painted',1),
                          ('pending_after_rating',True),('pending_after_rating',2)]:
            candidate=events();candidate['done'][1]['integrity'][key]=value
            with self.assertRaises(consumer.Refused):consumer.validate_events(candidate,PID,COMMIT)

    def test_frame_failures_keep_only_existing_closed_phase_labels(self):
        for phase in ['review_surface','rating_frame']:
            candidate=events()['done'][1]
            for key in ['timing_us','integrity']:del candidate[key]
            candidate.update(phase='failed',failure_code='synthetic_phase_failed',failed_phase=phase)
            result=consumer.closed_fixture_failure(candidate,PID,COMMIT)
            self.assertEqual(result.failed_phase,phase)


if __name__=='__main__':unittest.main()
