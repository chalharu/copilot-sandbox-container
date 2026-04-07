#!/usr/bin/env python3

import os
import pathlib
import sysconfig
import zipfile


wheel_path = pathlib.Path(os.environ["YAMLLINT_WHEEL_PATH"])
site_packages = pathlib.Path(sysconfig.get_path("purelib"))
site_packages.mkdir(parents=True, exist_ok=True)

with zipfile.ZipFile(wheel_path) as archive:
    for archive_name in archive.namelist():
        archive_path = pathlib.PurePosixPath(archive_name)
        if archive_path.is_absolute() or ".." in archive_path.parts:
            raise SystemExit(f"unsafe path in wheel: {archive_name}")
    archive.extractall(site_packages)

launcher = pathlib.Path("/usr/local/bin/yamllint")
launcher.write_text(
    "#!/usr/bin/env python3\n"
    "from yamllint.cli import run\n"
    "raise SystemExit(run())\n",
    encoding="utf-8",
)
launcher.chmod(0o755)
