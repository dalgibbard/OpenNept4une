import errno
import os
import pty
import select
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
N4FLASH_SOURCE = REPO_ROOT / 'img-config' / 'n4flash' / 'n4flash.c'


def crc16_usb(data):
    crc = 0xFFFF
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc ^ 0xFFFF


def build_frame(command, payload=b''):
    body = bytes((command, len(payload) >> 8, len(payload) & 0xFF)) + payload
    crc = crc16_usb(body)
    return b'\xA5' + body + bytes((crc >> 8, crc & 0xFF))


class N4FlashProtocolTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp_dir = tempfile.TemporaryDirectory()
        cls.root = Path(cls.temp_dir.name)
        cls.binary = cls.root / 'n4flash'
        compiler = shutil.which('cc') or shutil.which('gcc')
        if not compiler:
            raise unittest.SkipTest('no C compiler is available')
        subprocess.run(
            [
                compiler,
                '-O2',
                '-Wall',
                '-Wextra',
                '-Werror',
                '-o',
                str(cls.binary),
                str(N4FLASH_SOURCE),
            ],
            check=True,
        )
        cls.firmware = cls.root / 'firmware.bin'
        cls.firmware.write_bytes(bytes(range(256)) * 4)

    @classmethod
    def tearDownClass(cls):
        cls.temp_dir.cleanup()

    def run_with_fake_bootloader(
        self,
        acknowledge_end=True,
        acknowledge_start=True,
        unsolicited_hello_before_start_ack=False,
        unsolicited_hello_before_end_ack=False,
        stale_data_success_before_failure=False,
    ):
        master_fd, slave_fd = pty.openpty()
        slave_name = os.ttyname(slave_fd)
        process = subprocess.Popen(
            [str(self.binary), str(self.firmware), slave_name],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        os.close(slave_fd)

        received = bytearray()
        control_subcommands = []
        data_pages = []
        data_attempts = {}
        deadline = time.monotonic() + 12
        try:
            while process.poll() is None and time.monotonic() < deadline:
                readable, _, _ = select.select([master_fd], [], [], 0.1)
                if not readable:
                    continue
                try:
                    chunk = os.read(master_fd, 4096)
                except OSError as exc:
                    if exc.errno == errno.EIO:
                        # The child may not have opened/configured the slave
                        # side yet, or may just have closed it on exit.
                        time.sleep(0.01)
                        continue
                    raise
                if not chunk:
                    break
                received.extend(chunk)

                while len(received) >= 4:
                    if received[0] != 0xA5:
                        del received[0]
                        continue
                    payload_length = (received[2] << 8) | received[3]
                    frame_length = 6 + payload_length
                    if len(received) < frame_length:
                        break
                    frame = bytes(received[:frame_length])
                    del received[:frame_length]
                    command = frame[1]
                    payload = frame[4:4 + payload_length]

                    if command == 0x00:  # HELLO
                        os.write(master_fd, build_frame(0x00, b'\x01\x12'))
                    elif command == 0x02:  # DATA
                        page = int.from_bytes(payload[:4], 'big')
                        data_pages.append(page)
                        data_attempts[page] = data_attempts.get(page, 0) + 1
                        if (
                            stale_data_success_before_failure
                            and data_attempts[page] == 1
                        ):
                            wrong_page = (page + 1).to_bytes(4, 'big')
                            os.write(
                                master_fd,
                                build_frame(
                                    0x02,
                                    wrong_page + payload[4:6] + b'\x01',
                                ),
                            )
                            os.write(
                                master_fd,
                                build_frame(0x02, payload[:6] + b'\x02'),
                            )
                        else:
                            os.write(
                                master_fd,
                                build_frame(0x02, payload[:6] + b'\x01'),
                            )
                    elif command == 0x01 and len(payload) >= 2:  # CONTROL
                        subcommand = payload[0] | (payload[1] << 8)
                        control_subcommands.append(subcommand)
                        if subcommand == 0x0001:
                            if unsolicited_hello_before_start_ack:
                                os.write(master_fd, build_frame(0x00, b'\x01\x12'))
                            if not acknowledge_start:
                                continue
                        elif subcommand == 0x0102:
                            if unsolicited_hello_before_end_ack:
                                os.write(master_fd, build_frame(0x00, b'\x01\x12'))
                            if not acknowledge_end:
                                continue
                        os.write(master_fd, build_frame(0x01, b''))

            if process.poll() is None:
                process.kill()
                self.fail('n4flash timed out against the fake bootloader')
            output = process.communicate(timeout=1)[0]
            return process.returncode, output, control_subcommands, data_pages
        finally:
            os.close(master_fd)
            if process.poll() is None:
                process.kill()
                process.wait(timeout=1)

    def test_acknowledged_end_reports_success(self):
        returncode, output, _, _ = self.run_with_fake_bootloader(acknowledge_end=True)
        self.assertEqual(returncode, 0, output)
        self.assertIn('> done', output)

    def test_missing_end_ack_is_not_reported_as_success(self):
        returncode, output, _, _ = self.run_with_fake_bootloader(acknowledge_end=False)
        self.assertNotEqual(returncode, 0, output)
        self.assertIn('flash outcome is uncertain', output)
        self.assertIn('> failed', output)

    def test_unsolicited_hello_before_start_ack_is_ignored_without_resend(self):
        returncode, output, controls, _ = self.run_with_fake_bootloader(
            unsolicited_hello_before_start_ack=True,
        )
        self.assertEqual(returncode, 0, output)
        self.assertEqual(controls.count(0x0001), 1, controls)
        self.assertIn('ignoring unrelated command 0x00', output)

    def test_unacknowledged_start_attempts_abort_without_resending_start(self):
        returncode, output, controls, _ = self.run_with_fake_bootloader(
            acknowledge_start=False,
            unsolicited_hello_before_start_ack=True,
        )
        self.assertNotEqual(returncode, 0, output)
        self.assertEqual(controls.count(0x0001), 1, controls)
        self.assertIn(0x0202, controls)
        self.assertIn('START may have erased the application', output)
        self.assertIn('> failed', output)

    def test_unsolicited_hello_before_end_ack_is_ignored(self):
        returncode, output, _, _ = self.run_with_fake_bootloader(
            unsolicited_hello_before_end_ack=True,
        )
        self.assertEqual(returncode, 0, output)
        self.assertIn('ignoring unrelated command 0x00', output)

    def test_stale_data_success_cannot_skip_current_page_failure(self):
        returncode, output, _, data_pages = self.run_with_fake_bootloader(
            stale_data_success_before_failure=True,
        )
        self.assertEqual(returncode, 0, output)
        self.assertEqual(data_pages, [0, 0], data_pages)
        self.assertIn('ignoring stale/malformed DATA acknowledgement', output)


if __name__ == '__main__':
    unittest.main()
