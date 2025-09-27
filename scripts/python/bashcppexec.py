import subprocess, pathlib, argparse, os, sys

def compile_cpp(src: str, out: str | None = None, std: str = "c++20", flags: list[str] | None = None) -> None:
    src_path = pathlib.Path(src)
    if not src_path.is_file():
        raise FileNotFoundError(src)
    exe = out or src_path.stem
    cmd = ["g++", "-std=" + std, "-Wall", "-Wextra", "-O2"] + (flags or []) + ["-o", exe, str(src_path)]
    subprocess.run(cmd, check=True)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Compile a single C++ source file.")
    parser.add_argument("source", help="C++ source file")
    parser.add_argument("-o", "--output", help="output executable name")
    parser.add_argument("--std", default="c++20", help="C++ standard (default c++20)")
    parser.add_argument("--flags", nargs="*", help="extra compiler flags")
    args = parser.parse_args()
    compile_cpp(args.source, args.output, args.std, args.flags or [])
