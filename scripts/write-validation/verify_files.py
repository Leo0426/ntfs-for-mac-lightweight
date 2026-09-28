"""Read-only content comparison on macOS; does not establish mount or disk identity."""
import argparse
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from file_cycle import ValidationError, verify
from manifest_io import load_manifest


def main():
    parser = argparse.ArgumentParser(description='只读复验文件清单；不证明卷身份或发生过重挂载。')
    parser.add_argument('--root', required=True, help='已由调用方重新核对的卷根目录')
    parser.add_argument('--manifest', required=True, help='之前保存到测试卷外的清单文件')
    args = parser.parse_args()
    stage = 'manifestRead'
    try:
        manifest = load_manifest(args.manifest)
        stage = 'fileReadback'
        verify(args.root, manifest)
    except (ValidationError, OSError) as error:
        print(json.dumps({'status': 'failed', 'stage': stage,
                          'reason': str(error) if isinstance(error, ValidationError) else 'filesystemError',
                          'remountVerified': False, 'windowsVerified': False}, sort_keys=True))
        return 1
    print(json.dumps({'status': 'fileChecksPassed', 'retainedFiles': len(manifest['files']),
                      'deletedEntries': len(manifest['deleted']),
                      'remountVerified': False, 'windowsVerified': False}, sort_keys=True))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
