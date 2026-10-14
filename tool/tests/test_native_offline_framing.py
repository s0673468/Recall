"""Explicit short-packet transport; invented receipts and mocked ADB only."""
import base64
import hashlib
import json
import unittest
from unittest.mock import patch
from test_native_offline_driver import driver, cold
from test_native_offline_contract import fabricated_receipts, COMMIT


def packets_bytes(data):
    digest = hashlib.sha256(data).hexdigest()
    count = (len(data) + 239) // 240
    return [driver.CHUNK_SENTINEL + 'v1 %s %d %d %d %s' % (
        digest, len(data), index, count,
        base64.urlsafe_b64encode(data[index*240:(index+1)*240]).decode('ascii'))
        for index in range(count)]


def packets(value):
    return packets_bytes(json.dumps(value, ensure_ascii=False, separators=(',', ':')).encode())


class FramingTests(unittest.TestCase):
    def setUp(self):
        _, self.one, _ = fabricated_receipts()

    def decode(self, lines, **kw):
        return driver.closed_event('\n'.join('123.456 101 101 I flutter: '+x for x in lines),
                                   'offline_recorded', 101, COMMIT, **kw)

    def refused(self, lines, code):
        with self.assertRaises(driver.contract.Refused) as caught:
            self.decode(lines)
        self.assertEqual(caught.exception.code, code)
        self.assertFalse(hasattr(caught.exception, 'body'))
        return caught.exception

    def test_complete_known_receipt_retains_identity_and_schema(self):
        lines = packets(self.one)
        self.assertGreater(len(lines), 1)
        self.assertTrue(all(len(x.encode()) <= 512 and x.isascii() for x in lines))
        self.assertEqual(self.decode(lines), self.one)

    def test_cross_language_golden(self):
        # The exact same compact UTF-8 golden is asserted in the Dart test.
        data = '{"fixture":"é😀","n":1}'.encode()
        expected = ('RECALL_NATIVE_OFFLINE_CHUNK v1 '
                    +hashlib.sha256(data).hexdigest()+' 26 0 1 eyJmaXh0dXJlIjoiw6nwn5iAIiwibiI6MX0=')
        self.assertEqual(packets_bytes(data), [expected])
        self.assertEqual(driver.receipt_bodies(expected), [data.decode()])

    def test_missing_tail_direct_refuses_and_poll_prefix_is_pending(self):
        lines = packets(self.one)[:-1]
        self.refused(lines, 'fixture_frame_incomplete')
        self.assertIsNone(self.decode(lines, allow_incomplete=True))

    def test_partial_then_complete_snapshot_completes_without_cross_poll_stitching(self):
        lines = packets(self.one)
        snapshots = iter(['\n'.join(lines[:-1]), '\n'.join(lines)])
        def adb(serial, *args, **kw):
            if args[:3] == ('shell','am','start'): return 'fixture launch'
            if args[:2] == ('shell','pidof'): return '101'
            return next(snapshots)
        with patch.object(cold, 'adb', adb), patch.object(driver.time, 'sleep'):
            self.assertEqual(driver.phase('emulator-5554','fixture.Activity','offline_recorded',COMMIT,15), self.one)

    def test_missing_tail_exhausts_existing_deadline_and_refuses(self):
        incomplete = '\n'.join(packets(self.one)[:-1])
        def adb(serial, *args, **kw):
            if args[:3] == ('shell','am','start'): return 'fixture launch'
            if args[:2] == ('shell','pidof'): return '101'
            return incomplete
        # deadline=15; one poll at0, next loop at16. No real waits/runtime.
        ticks = iter([0,0,0,0,16])
        with patch.object(cold, 'adb', adb), patch.object(driver.time, 'monotonic', side_effect=lambda:next(ticks)), patch.object(driver.time, 'sleep'):
            with self.assertRaises(driver.contract.Refused) as caught:
                driver.phase('emulator-5554','fixture.Activity','offline_recorded',COMMIT,15)
        self.assertEqual(caught.exception.code, 'fixture_frame_incomplete')

    def test_duplicate_reordered_and_missing_first_refuse(self):
        lines = packets(self.one)
        for bad in ([lines[0], *lines], [lines[1], lines[0], *lines[2:]], lines[1:]):
            with self.subTest(kind=len(bad)):
                self.refused(bad, 'fixture_packet_sequence_invalid')

    def test_mixed_frame_identity_refuses(self):
        lines = packets(self.one)
        _,_,two = fabricated_receipts()
        self.refused([lines[0], packets(two)[1]], 'fixture_packet_sequence_invalid')

    def test_mixed_legacy_and_packets_refuses(self):
        self.refused([driver.SENTINEL+json.dumps(self.one), *packets(self.one)], 'fixture_frame_mixed_protocol')

    def test_complete_duplicate_frame_refuses(self):
        lines = packets(self.one)
        self.refused(lines+lines, 'fixture_packet_sequence_invalid')

    def test_malformed_truncated_unknown_version_and_oversize_packets_refuse(self):
        lines = packets(self.one)
        for line in [lines[0][:-1], lines[0].replace(' v1 ', ' v2 '),
                     driver.CHUNK_SENTINEL+'x'*513,
                     lines[0]+' payload', lines[0]+'é']:
            with self.subTest(size=len(line)):
                with self.assertRaises(driver.contract.Refused):
                    self.decode([line], allow_incomplete=True)

    def test_metadata_and_noncanonical_numbers_refuse(self):
        lines=packets(self.one)
        fields=lines[0].split()
        for index,value in [(3,'8193'),(3,'01'),(4,'01'),(5,'99'),(5,'0')]:
            bad=fields.copy();bad[index]=value
            with self.subTest(index=index,value=value),self.assertRaises(driver.contract.Refused):
                self.decode([' '.join(bad)])

    def test_checksum_length_and_base64_refuse(self):
        lines=packets(self.one)
        wrong=[x.replace(x.split()[2], 'f'*64) for x in lines]
        self.refused(wrong, 'fixture_frame_checksum_invalid')
        fields=lines[0].split();fields[-1]='AAAA'
        self.refused([' '.join(fields)], 'fixture_packet_length_invalid')
        fields[-1]='AA=A'
        self.refused([' '.join(fields)], 'fixture_packet_invalid')
        fields[-1]='AAA'
        self.refused([' '.join(fields)], 'fixture_packet_encoding_invalid')
        # Noncanonical pad bits decode to the same byte but must still refuse.
        data=b'\x00';short=packets_bytes(data);short[0]=short[0][:-4]+'AB=='
        self.refused(short, 'fixture_packet_encoding_invalid')

    def test_invalid_utf8_and_json_are_not_ignored(self):
        self.refused(packets_bytes(b'\xff'), 'fixture_frame_utf8_invalid')
        self.refused(packets_bytes(b'{"private":'), 'fixture_json_invalid')

    def test_wrong_pid_source_schema_and_phase_still_refuse(self):
        for update,code in [({'pid':202},'fixture_process_identity_invalid'),
                            ({'source_commit':'b'*40},'fixture_process_identity_invalid'),
                            ({'schema':'unknown'},'fixture_schema_invalid'),
                            ({'phase':'restart_synced'},'fixture_phase_invalid')]:
            self.refused(packets({**self.one,**update}),code)

    def test_framed_pair_preserves_all_native_semantic_qualification(self):
        launch,one,two=fabricated_receipts()
        parsed_one=driver.closed_event('\n'.join(packets(one)),'offline_recorded',101,COMMIT)
        parsed_two=driver.closed_event('\n'.join(packets(two)),'restart_synced',202,COMMIT)
        self.assertTrue(driver.contract.validate(launch,parsed_one,parsed_two,COMMIT)['qualification_passed'])
        for update in [{'owner_sha256':'f'*64},{'event_sha256':'f'*64},
                       {'snapshot_identity_sha256':'f'*64},{'pending_after_lost_ack':0},
                       {'other_owner_pending_count':1},{'native_remove_ack_observed':False},
                       {'real_provider_contacted':True}]:
            parsed=driver.closed_event('\n'.join(packets({**two,**update})),'restart_synced',202,COMMIT)
            with self.subTest(field=next(iter(update))),self.assertRaises(driver.contract.Refused):
                driver.contract.validate(launch,parsed_one,parsed,COMMIT)

    def test_repeated_log_snapshot_is_not_cross_snapshot_duplicate(self):
        raw='\n'.join(packets(self.one))
        self.assertEqual(driver.closed_event(raw,'offline_recorded',101,COMMIT),self.one)
        self.assertEqual(driver.closed_event(raw,'offline_recorded',101,COMMIT),self.one)

    def test_oversize_frame_declared_before_assembly_refuses(self):
        with self.assertRaises(driver.contract.Refused):
            driver.receipt_bodies('\n'.join(packets_bytes(b'x'*8193)))

    def test_failure_allowlist_remains_in_force(self):
        failed={'schema':driver.contract.SCHEMA,'pid':101,'source_commit':COMMIT,'phase':'failed',
                'failure_code':'synthetic_phase_failed','failed_phase':'offline_recording',
                'failed_assertion_stage':'online_ready'}
        error=self.refused(packets(failed), 'fixture_reported_failure')
        self.assertEqual(error.failed_assertion_stage,'online_ready')
        failed['failed_assertion_stage']='private-payload'
        self.refused(packets(failed), 'fixture_failure_schema_invalid')

    def test_unicode_may_cross_byte_chunk_boundary_without_loss(self):
        data=('"'+'é😀'*200+'"').encode()
        self.assertGreater(len(data),1023)
        self.assertEqual(driver.receipt_bodies('\n'.join(packets_bytes(data))),[data.decode()])


if __name__ == '__main__': unittest.main()
