#!/usr/bin/env python3
"""Regenerate assets/qr.png. The code points at the public TestFlight link."""
import pathlib
import qrcode

root = pathlib.Path(__file__).resolve().parent.parent
qr = qrcode.QRCode(error_correction=qrcode.constants.ERROR_CORRECT_M, box_size=20, border=2)
qr.add_data("https://testflight.apple.com/join/tHKQsbCk")
qr.make(fit=True)
img = qr.make_image(fill_color="#0F1115", back_color="white").convert("RGB")
img.save(root / "assets" / "qr.png")
print("wrote", root / "assets" / "qr.png", img.size)
