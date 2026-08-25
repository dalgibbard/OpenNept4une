import hashlib
import struct
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
DTB_DIR = REPO_ROOT / "dtb" / "n4plus-n4max-v2.3"
DTB = DTB_DIR / "rk3328-znp-n4plus-n4max-v2.3.dtb"
DTS = DTB_DIR / "rk3328-znp-n4plus-n4max-v2.3.dts"
GUIDE = REPO_ROOT / "docs" / "neptune-4-max-znp-k1-2.3-usb-c-guide.md"
EXPECTED_DTB_SHA256 = "808c234c5cedb0e5f70d87fc7973d9e2693a7e38563c5ad62c99417b7d22c92b"


def parse_dtb_properties(data):
    header = struct.unpack_from(">10I", data)
    magic, _, struct_offset, strings_offset, _, _, _, _, strings_size, struct_size = header
    if magic != 0xD00DFEED:
        raise ValueError("invalid flattened device-tree magic")

    structure = data[struct_offset : struct_offset + struct_size]
    strings = data[strings_offset : strings_offset + strings_size]
    offset = 0
    path = []
    properties = {}

    while offset < len(structure):
        token = struct.unpack_from(">I", structure, offset)[0]
        offset += 4
        if token == 1:  # FDT_BEGIN_NODE
            end = structure.index(b"\0", offset)
            path.append(structure[offset:end].decode())
            offset = (end + 4) & ~3
        elif token == 2:  # FDT_END_NODE
            path.pop()
        elif token == 3:  # FDT_PROP
            length, name_offset = struct.unpack_from(">II", structure, offset)
            offset += 8
            end = strings.index(b"\0", name_offset)
            name = strings[name_offset:end].decode()
            value = structure[offset : offset + length]
            offset = (offset + length + 3) & ~3
            node_path = "/" + "/".join(component for component in path if component)
            properties.setdefault(node_path, {})[name] = value
        elif token == 4:  # FDT_NOP
            continue
        elif token == 9:  # FDT_END
            break
        else:
            raise ValueError(f"unexpected flattened device-tree token: {token}")

    return properties


def cells(value):
    if len(value) % 4:
        raise ValueError("device-tree cell property is not 32-bit aligned")
    return struct.unpack(f">{len(value) // 4}I", value)


class Board23DeviceTreeTests(unittest.TestCase):
    def test_committed_binary_and_documented_checksum_agree(self):
        digest = hashlib.sha256(DTB.read_bytes()).hexdigest()
        self.assertEqual(digest, EXPECTED_DTB_SHA256)
        self.assertIn(EXPECTED_DTB_SHA256, GUIDE.read_text())

    def test_rk805_interrupt_matches_gpio2_pa6_pinctrl(self):
        properties = parse_dtb_properties(DTB.read_bytes())
        pmic = properties["/i2c@ff160000/pmic@18"]
        pmic_pin = properties["/pinctrl/pmic/pmic-int-l"]

        self.assertEqual(cells(pmic["interrupts"]), (6, 8))
        self.assertEqual(cells(pmic_pin["rockchip,pins"])[:2], (2, 6))

    def test_source_uses_the_same_rk805_interrupt(self):
        source = DTS.read_text()
        self.assertIn("interrupts = <0x06 0x08>;", source)
        self.assertIn("rockchip,pins = <0x02 0x06 0x00 0x66>;", source)


if __name__ == "__main__":
    unittest.main()
