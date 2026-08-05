import json
import socket
import threading
import tempfile
import time
import types
import unittest
from unittest import mock

import ultimate_radar_server as radar


HOME = radar.Scope(39.117210, -94.635600, 9).validated()


class FakeResponse:
    def __init__(self, payload):
        self.body = json.dumps(payload).encode()

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, traceback):
        return False

    def read(self):
        return self.body


def fixture_payload(count=10):
    aircraft = []
    for index in reversed(range(count)):
        aircraft.append({
            "hex": f"a{index:05x}",
            "flight": f"TEST{index + 1}",
            "t": "B738",
            "lat": HOME.latitude + 0.002 + index * 0.001,
            "lon": HOME.longitude,
            "alt_baro": 1200 + index * 500,
            "gs": 95 + index * 10,
            "track": index * 45,
        })
    return {"ac": aircraft}


class GeometryTests(unittest.TestCase):
    def test_known_distance_bearing_projection(self):
        nearby = (39.209, -94.554)
        self.assertAlmostEqual(radar.distance_nm((HOME.latitude, HOME.longitude), nearby), 6.69, places=2)
        self.assertAlmostEqual(radar.bearing_degrees((HOME.latitude, HOME.longitude), nearby), 34.6, places=1)
        self.assertEqual(radar.project_to_scope(34.6, 6.69, 9), (140, 42))

    def test_filters_slow_missing_and_out_of_range(self):
        """Airborne traffic below the speed floor, without a position, or out
        of range is dropped. Ground traffic is kept (see the ordering test)."""
        payload = fixture_payload(2)
        payload["ac"].extend([
            {"flight": "SLOW", "lat": HOME.latitude, "lon": HOME.longitude, "alt_baro": 500, "gs": 20},
            {"flight": "NOPOS", "alt_baro": 500, "gs": 80},
            {"flight": "FAR", "lat": HOME.latitude + 1, "lon": HOME.longitude, "alt_baro": 500, "gs": 80},
        ])
        targets = radar.extract_targets(payload, HOME)
        self.assertEqual([target["callsign"] for target in targets], ["TEST1", "TEST2"])

    def test_ground_traffic_is_kept_but_ranked_below_airborne(self):
        """Grounded aircraft are shown but always sort after airborne ones, so
        they are the first to be dropped when more than 8 targets are in
        range. The airborne speed floor deliberately does not apply to them --
        taxiing aircraft are slow by nature."""
        payload = fixture_payload(2)
        payload["ac"].extend([
            # Closer than either airborne target, and slow, but on the ground.
            {"flight": "TAXI", "lat": HOME.latitude, "lon": HOME.longitude,
             "alt_baro": "ground", "gs": 15},
        ])
        targets = radar.extract_targets(payload, HOME)
        self.assertEqual([target["callsign"] for target in targets],
                         ["TEST1", "TEST2", "TAXI"])
        self.assertTrue(targets[-1]["ground"])
        self.assertFalse(any(target["ground"] for target in targets[:-1]))
        # Grounded targets report no altitude/vertical rate.
        self.assertIsNone(targets[-1]["alt"])


class WireTests(unittest.TestCase):
    def test_blob_is_capped_and_truncated(self):
        targets = radar.extract_targets(fixture_payload(10), HOME)
        snapshot = radar.Snapshot(HOME, targets, len(targets), time.time(), time.monotonic(), time.monotonic(), False)
        blob = radar.build_blob(snapshot)
        self.assertEqual(len(blob), 8 + 8 * 28)
        self.assertEqual(blob[:3], b"LD\x01")
        self.assertEqual(blob[3] & 0x02, 0x02)
        self.assertEqual(blob[4], 8)
        self.assertEqual(blob[5], 10)

    def test_unknown_values_set_status_bits(self):
        target = {
            "callsign": "UNKNOWN",
            "type": "----",
            "alt": None,
            "gs": None,
            "trk": None,
            "distance": 1,
            "bearing": 0,
        }
        record = radar.pack_record(target, HOME)
        self.assertEqual(record[3] & 0x07, 0x07)
        self.assertEqual(record[4], 0)
        self.assertEqual(record[5], 0)


class RequestTests(unittest.TestCase):
    def test_default_request_is_backward_compatible(self):
        scope, warning = radar.parse_location_command(b"", HOME, {})
        self.assertEqual(scope, HOME)
        self.assertIsNone(warning)

    def test_future_position_request(self):
        scope, warning = radar.parse_location_command(b"MR2 POS 40.6413 -73.7781 12\n", HOME, {})
        self.assertIsNone(warning)
        self.assertEqual(scope, radar.Scope(40.6413, -73.7781, 12).validated())

    def test_future_icao_request(self):
        scope, warning = radar.parse_location_command(b"MR2 ICAO EGLL 9\n", HOME, {"EGLL": (51.470748, -0.459909)})
        self.assertIsNone(warning)
        self.assertEqual(scope, radar.Scope(51.470748, -0.459909, 9).validated())


class AirportDatabaseTests(unittest.TestCase):
    def test_parse_ourairports_icao_coordinates(self):
        """Entries are (latitude, longitude, elevation_ft); elevation is used
        for QNH-adjusted altitude and is None when the CSV omits it."""
        data = (
            b'id,ident,latitude_deg,longitude_deg,elevation_ft,icao_code\n'
            b'1,KPVD,41.725038,-71.425668,55,KPVD\n'
            b'2,NOELEV,10.5,20.5,,EGLL\n'
            b'3,LOCAL,10,20,,\n'
        )
        airports = radar.parse_airports_csv(data)
        self.assertEqual(airports["KPVD"], (41.725038, -71.425668, 55.0))
        self.assertEqual(airports["EGLL"], (10.5, 20.5, None))
        self.assertNotIn("LOCAL", airports)

    def test_cached_database_merges_configured_overrides(self):
        config = radar.ServerConfig(
            default_scope=HOME,
            airports={"EGLL": (51.470748, -0.459909)},
        ).validate()
        with tempfile.TemporaryDirectory() as directory:
            path = radar.Path(directory) / "airports_cache.json"
            path.write_text(json.dumps({
                "updated": time.time(),
                "airports": {"KPVD": [41.725038, -71.425668]},
            }))
            message = radar.load_airport_database(config, path)
        self.assertIn("KPVD", config.airports)
        self.assertIn("EGLL", config.airports)
        self.assertIn("2 fallback airport(s)", message)

    def test_download_uses_second_source_after_primary_failure(self):
        config = radar.ServerConfig(default_scope=HOME).validate()
        response = mock.MagicMock()
        response.__enter__.return_value = response
        response.read.return_value = b"csv"
        airports = {}
        for index in range(1000):
            code = "X" + "".join((
                chr(65 + (index // 676) % 26),
                chr(65 + (index // 26) % 26),
                chr(65 + index % 26),
            ))
            airports[code] = (1.0, 2.0)
        airports["EGLL"] = (51.470748, -0.459909)
        with tempfile.TemporaryDirectory() as directory:
            path = radar.Path(directory) / "airports_cache.json"
            with mock.patch.object(
                radar.urllib.request,
                "urlopen",
                side_effect=[OSError("primary offline"), response],
            ) as urlopen, mock.patch.object(
                radar,
                "parse_airports_csv",
                return_value=airports,
            ):
                message = radar.load_airport_database(config, path)
        self.assertEqual(urlopen.call_count, 2)
        self.assertEqual(config.airports["EGLL"], (51.470748, -0.459909))
        self.assertIn("1,001 airport(s)", message)


class ServiceTests(unittest.TestCase):
    def test_direct_fetch_and_cache(self):
        config = radar.ServerConfig(default_scope=HOME, port=0).validate()
        service = radar.TrafficService(config)
        with mock.patch.object(radar.urllib.request, "urlopen", return_value=FakeResponse(fixture_payload(3))) as request:
            first = service.refresh(HOME, force=True)
            second = service.refresh(HOME)
        self.assertFalse(first.stale)
        self.assertEqual(first.total, 3)
        self.assertIs(first, second)
        self.assertEqual(request.call_count, 1)

    def test_brief_failed_fetch_preserves_cache_without_stale_warning(self):
        config = radar.ServerConfig(default_scope=HOME, port=0).validate()
        service = radar.TrafficService(config)
        targets = radar.extract_targets(fixture_payload(2), HOME)
        old = radar.Snapshot(HOME, targets, 2, time.time(), 0, time.monotonic(), False)
        service._snapshots[HOME] = old
        with mock.patch.object(radar.urllib.request, "urlopen", side_effect=OSError("offline")):
            snapshot = service.refresh(HOME, force=True)
        self.assertFalse(snapshot.stale)
        self.assertEqual(snapshot.targets, targets)
        self.assertEqual(radar.build_blob(snapshot)[3] & 0x01, 0)

    def test_sustained_failed_fetch_marks_old_cache_stale(self):
        config = radar.ServerConfig(default_scope=HOME, port=0).validate()
        service = radar.TrafficService(config)
        targets = radar.extract_targets(fixture_payload(2), HOME)
        old = radar.Snapshot(
            HOME, targets, 2, time.time() - 31, 0, time.monotonic(), False
        )
        service._snapshots[HOME] = old
        with mock.patch.object(radar.urllib.request, "urlopen", side_effect=OSError("offline")):
            snapshot = service.refresh(HOME, force=True)
        self.assertTrue(snapshot.stale)
        self.assertEqual(radar.build_blob(snapshot)[3] & 0x01, 0x01)


class MailboxTests(unittest.TestCase):
    def test_payload_roundtrip(self):
        payload = radar.build_mailbox_payload("192.168.1.50")
        self.assertEqual(len(payload), 18)
        blob = radar.MAILBOX_MAGIC + bytes([radar.MAILBOX_VERSION]) + payload
        running, ip = radar.parse_mailbox(blob)
        self.assertTrue(running)
        self.assertEqual(ip, "192.168.1.50")

    def test_bad_checksum_is_running_but_unset(self):
        payload = bytearray(radar.build_mailbox_payload("192.168.1.50"))
        payload[-1] ^= 0xFF
        blob = radar.MAILBOX_MAGIC + bytes([radar.MAILBOX_VERSION]) + bytes(payload)
        running, ip = radar.parse_mailbox(blob)
        self.assertTrue(running)
        self.assertIsNone(ip)

    def test_missing_magic_means_not_running(self):
        running, ip = radar.parse_mailbox(bytes(radar.MAILBOX_SIZE))
        self.assertFalse(running)
        self.assertIsNone(ip)

    def test_empty_slot_is_running_but_unset(self):
        blob = (
            radar.MAILBOX_MAGIC
            + bytes([radar.MAILBOX_VERSION])
            + bytes(18)
        )
        running, ip = radar.parse_mailbox(blob)
        self.assertTrue(running)
        self.assertIsNone(ip)

    def test_rejects_impossible_addresses(self):
        with self.assertRaises(ValueError):
            radar.build_mailbox_payload("1.2.3")
        with self.assertRaises(ValueError):
            radar.build_mailbox_payload("1234.5678.9.10.11")


class FakeUltimateApi:
    """Stands in for UltimatePusher._api against 64K of fake C64 RAM."""

    def __init__(self):
        self.memory = bytearray(65536)
        self.writes = []

    def __call__(self, host, path, method="GET"):
        if path == "/v1/version":
            return json.dumps({"product": "Fake U64", "firmware_version": "3.12"}).encode()
        if path.startswith("/v1/machine:readmem"):
            query = dict(pair.split("=") for pair in path.split("?")[1].split("&"))
            address = int(query["address"], 16)
            length = int(query["length"])
            return bytes(self.memory[address:address + length])
        if path.startswith("/v1/machine:writemem"):
            assert method == "PUT"
            query = dict(pair.split("=") for pair in path.split("?")[1].split("&"))
            address = int(query["address"], 16)
            data = bytes.fromhex(query["data"])
            self.memory[address:address + len(data)] = data
            self.writes.append((address, data))
            return b"{}"
        raise AssertionError(f"unexpected API path {path}")


class UltimatePusherTests(unittest.TestCase):
    def make_pusher(self, fake, lan=("192.168.4.20",)):
        config = radar.ServerConfig(default_scope=HOME).validate()
        pusher = radar.UltimatePusher(config, list(lan))
        pusher._api = fake
        return pusher

    def plant_mailbox(self, fake, ip=None):
        base = radar.MAILBOX_ADDRESS
        fake.memory[base:base + 4] = radar.MAILBOX_MAGIC
        fake.memory[base + 4] = radar.MAILBOX_VERSION
        if ip:
            payload = radar.build_mailbox_payload(ip)
            fake.memory[base + 5:base + 5 + len(payload)] = payload

    def test_pushes_ip_when_radar_running(self):
        fake = FakeUltimateApi()
        self.plant_mailbox(fake)
        pusher = self.make_pusher(fake)
        message = pusher.poll_host("192.168.4.64")
        self.assertIn("192.168.4.20", message)
        running, ip = radar.parse_mailbox(
            bytes(fake.memory[radar.MAILBOX_ADDRESS:radar.MAILBOX_ADDRESS + radar.MAILBOX_SIZE])
        )
        self.assertTrue(running)
        self.assertEqual(ip, "192.168.4.20")
        self.assertEqual(fake.writes[0][0], radar.MAILBOX_ADDRESS + 5)

    def test_skips_machine_without_radar(self):
        fake = FakeUltimateApi()
        pusher = self.make_pusher(fake)
        self.assertIsNone(pusher.poll_host("192.168.4.64"))
        self.assertEqual(fake.writes, [])

    def test_skips_when_mailbox_is_current(self):
        fake = FakeUltimateApi()
        self.plant_mailbox(fake, ip="192.168.4.20")
        pusher = self.make_pusher(fake)
        self.assertIsNone(pusher.poll_host("192.168.4.64"))
        self.assertEqual(fake.writes, [])

    def test_overwrites_stale_mailbox_ip(self):
        fake = FakeUltimateApi()
        self.plant_mailbox(fake, ip="10.9.9.9")
        pusher = self.make_pusher(fake)
        self.assertIsNotNone(pusher.poll_host("192.168.4.64"))
        running, ip = radar.parse_mailbox(
            bytes(fake.memory[radar.MAILBOX_ADDRESS:radar.MAILBOX_ADDRESS + radar.MAILBOX_SIZE])
        )
        self.assertEqual(ip, "192.168.4.20")

    def test_server_ip_prefers_matching_subnet(self):
        fake = FakeUltimateApi()
        pusher = self.make_pusher(fake, lan=("10.0.0.5", "192.168.4.20"))
        self.assertEqual(pusher.server_ip_for("192.168.4.64"), "192.168.4.20")
        self.assertEqual(pusher.server_ip_for("10.0.0.9"), "10.0.0.5")
        self.assertEqual(pusher.server_ip_for("172.16.0.4"), "10.0.0.5")

    def test_interval_validation(self):
        with self.assertRaises(radar.ConfigurationError):
            radar.ServerConfig(default_scope=HOME, ultimate_interval_seconds=1.0).validate()


class StubTraffic:
    def __init__(self):
        self.last_scope = None

    def get(self, scope):
        self.last_scope = scope
        return radar.Snapshot(scope, [], 0, time.time(), time.monotonic(), time.monotonic(), False)

    def status(self):
        return []


class ServerProtocolTests(unittest.TestCase):
    def setUp(self):
        self.config = radar.ServerConfig(default_scope=HOME, bind="127.0.0.1", port=0, peek_seconds=0.05).validate()
        self.traffic = StubTraffic()
        self.server = types.SimpleNamespace(
            config=self.config,
            traffic=self.traffic,
            lan_addresses=["192.168.1.50"],
            server_address=("127.0.0.1", 6464),
            started_time=time.time(),
        )

    def receive_all(self, request=b""):
        client, handler_socket = socket.socketpair()
        client.settimeout(2)
        try:
            if request:
                client.sendall(request)
            client.shutdown(socket.SHUT_WR)

            def run_handler():
                try:
                    radar.RadarRequestHandler(handler_socket, ("local", 0), self.server)
                finally:
                    handler_socket.close()

            thread = threading.Thread(target=run_handler, daemon=True)
            thread.start()
            chunks = []
            while True:
                chunk = client.recv(1024)
                if not chunk:
                    break
                chunks.append(chunk)
            thread.join(timeout=2)
            self.assertFalse(thread.is_alive())
            return b"".join(chunks)
        finally:
            client.close()

    def test_existing_c64_raw_connection(self):
        response = self.receive_all()
        self.assertEqual(response, b"LD\x01\x00\x00\x00\x00\x00")
        self.assertEqual(self.traffic.last_scope, HOME)

    def test_future_position_connection(self):
        response = self.receive_all(b"MR2 POS 40.6413 -73.7781 9\n")
        self.assertTrue(response.startswith(b"LD"))
        self.assertEqual(self.traffic.last_scope, radar.Scope(40.6413, -73.7781, 9).validated())

    def test_unknown_icao_returns_location_error_not_default_traffic(self):
        response = self.receive_all(b"MR2 ICAO KPVD 9\n")
        self.assertEqual(response, b"LD\x01\x04\x00\x00\xff\x00")
        self.assertIsNone(self.traffic.last_scope)

    def test_configured_icao_recenters(self):
        self.config.airports["KPVD"] = (41.725038, -71.425668)
        response = self.receive_all(b"MR2 ICAO KPVD 9\n")
        self.assertTrue(response.startswith(b"LD"))
        self.assertEqual(
            self.traffic.last_scope,
            radar.Scope(41.725038, -71.425668, 9).validated(),
        )

    def test_http_status(self):
        response = self.receive_all(b"GET /status.json HTTP/1.0\r\n\r\n")
        self.assertTrue(response.startswith(b"HTTP/1.0 200 OK"))
        self.assertIn(b'"application": "C64 Ultimate Radar Server"', response)


if __name__ == "__main__":
    unittest.main()
