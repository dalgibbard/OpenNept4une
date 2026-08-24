import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


class GenerateConfigTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        self.home = self.root / 'home'
        self.home.mkdir()
        self.config_dir = self.home / 'printer_data' / 'config'
        self.config_dir.mkdir(parents=True)
        self.confs = self.root / 'printer-confs'
        shutil.copytree(REPO_ROOT / 'printer-confs', self.confs)
        self.generator = self.confs / 'generate_conf.py'

    def tearDown(self):
        self.temp_dir.cleanup()

    def run_generator(self, *args, serial_paths=()):
        serial_dir = self.root / 'dev' / 'serial' / 'by-id'
        serial_dir.mkdir(parents=True, exist_ok=True)
        for name in serial_paths:
            (serial_dir / name).touch()

        env = os.environ.copy()
        env['HOME'] = str(self.home)
        env['OPENNEPT4UNE_USB_TOOLHEAD_SERIAL_GLOB'] = str(
            serial_dir / 'usb-Klipper_stm32f103xe_*'
        )
        return subprocess.run(
            [sys.executable, str(self.generator), *args],
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_n4max_usb_c_uses_thr_part_light_without_neopixel_conflict(self):
        serial_name = 'usb-Klipper_stm32f103xe_TEST-if00'
        result = self.run_generator(
            'n4max', '--toolhead', 'usb-c', serial_paths=(serial_name,)
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

        output = (self.confs / 'output.cfg').read_text()
        self.assertIn('[include MCU_ID.cfg]', output)
        self.assertRegex(
            output,
            r'\[output_pin Part_Light\]\s+pin: THR:PB10(?:\s|$)',
        )
        self.assertEqual(output.count('THR:PB10'), 1)
        self.assertNotIn('[neopixel toolhead_led]', output)
        self.assertIn('pin: THR:PB1', output)
        self.assertIn('[lis2dw x]', output)
        self.assertNotIn('{{', output)

        mcu_id = (self.config_dir / 'MCU_ID.cfg').read_text()
        expected_serial = self.root / 'dev' / 'serial' / 'by-id' / serial_name
        self.assertEqual(
            mcu_id,
            '[mcu THR]\n'
            f'serial: {expected_serial}\n'
            'restart_method: command\n',
        )

    def test_n4max_ribbon_keeps_host_part_light(self):
        result = self.run_generator('n4max', '--toolhead', 'ribbon')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

        output = (self.confs / 'output.cfg').read_text()
        self.assertRegex(
            output,
            r'\[output_pin Part_Light\]\s+pin: rpi:gpiochip2/gpio15(?:\s|$)',
        )
        self.assertNotIn('[mcu THR]', output)
        self.assertNotIn('THR:PB10', output)
        self.assertFalse((self.config_dir / 'MCU_ID.cfg').exists())

    def test_usb_c_requires_exactly_one_persistent_serial(self):
        no_device = self.run_generator('n4max', '--toolhead', 'usb-c')
        self.assertNotEqual(no_device.returncode, 0)
        self.assertIn('no USB-C toolhead found', no_device.stdout)

        multiple = self.run_generator(
            'n4max',
            '--toolhead',
            'usb-c',
            serial_paths=(
                'usb-Klipper_stm32f103xe_ONE-if00',
                'usb-Klipper_stm32f103xe_TWO-if00',
            ),
        )
        self.assertNotEqual(multiple.returncode, 0)
        self.assertIn('multiple USB-C toolhead devices found', multiple.stdout)

    def test_invalid_toolhead_is_rejected(self):
        result = self.run_generator('n4max', '--toolhead', 'type-c')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('invalid --toolhead value', result.stdout)


if __name__ == '__main__':
    unittest.main()
