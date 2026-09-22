#!/bin/sh
# Patch an untouched JetBrains Toolbox Linux tar installation for
# native Wayland rendering. Copy this file into the bundle's bin directory and
# run it there. Run with --rollback to restore the original vendor files.
set -eu

TOOLBOX_VERSION="3.8.1.88030"
ELF_SHA256='9e3fc1ad90595699f00945c934221d7f02164f08c03f6fcfea00ad50fe119529'
JAR_SHA256='f19f167c0e27998d7066239973279cbe2d5bed85ed25984537cf02ea2bf19d8c'
JAR_REL='lib/ui-desktop-1.10.0-SNAPSHOT+data-source-prototype-1-10-0-beta02.jar'
CLASS_REL='androidx/compose/ui/awt/ComposeWindowPanel.class'

fail() {
    printf 'Native Wayland installer: %s\n' "$*" >&2
    exit 1
}

sha256() {
    sha256sum "$1" | cut -d' ' -f1
}

SCRIPT_PATH=$(readlink -f -- "$0")
BIN_DIR=$(CDPATH= cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd)
cd "$BIN_DIR"

rollback() {
    test -f jetbrains-toolbox.vendor || fail 'jetbrains-toolbox.vendor is missing'
    test -f "$JAR_REL.vendor" || fail "$JAR_REL.vendor is missing"
    test "$(sha256 jetbrains-toolbox.vendor)" = "$ELF_SHA256" || fail 'vendor launcher checksum mismatch'
    test "$(sha256 "$JAR_REL.vendor")" = "$JAR_SHA256" || fail 'vendor JAR checksum mismatch'
    cp -p jetbrains-toolbox.vendor jetbrains-toolbox
    cp -p "$JAR_REL.vendor" "$JAR_REL"
    printf '%s\n' 'Restored the original JetBrains Toolbox launcher and JAR.'
}

case "${1-}" in
    --rollback)
        test "$#" -eq 1 || fail 'usage: install-native-wayland.sh [--rollback]'
        rollback
        exit 0
        ;;
    '') ;;
    *) fail 'usage: install-native-wayland.sh [--rollback]' ;;
esac

test -f jetbrains-toolbox || fail 'run this script from the Toolbox bin directory'
test -f "$JAR_REL" || fail "$JAR_REL is missing"
test ! -e jetbrains-toolbox.vendor || fail 'jetbrains-toolbox.vendor already exists; this does not look like a fresh install'
test ! -e "$JAR_REL.vendor" || fail "$JAR_REL.vendor already exists; this does not look like a fresh install"
test "$(sha256 jetbrains-toolbox)" = "$ELF_SHA256" || fail "unknown launcher checksum; expected Toolbox $TOOLBOX_VERSION"
test "$(sha256 "$JAR_REL")" = "$JAR_SHA256" || fail 'unknown ui-desktop JAR checksum; refusing to patch it'

WORK_DIR=$(mktemp -d /tmp/toolbox-native-wayland.XXXXXX)
cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$(dirname "$WORK_DIR/classes/$CLASS_REL")" "$WORK_DIR/patcher"
unzip -q "$JAR_REL" "$CLASS_REL" -d "$WORK_DIR/classes"

cat > "$WORK_DIR/ComposeWindowPanelPatcher.java" <<'__TOOLBOX_PATCHER_SOURCE__'
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;

import jdk.internal.org.objectweb.asm.ClassReader;
import jdk.internal.org.objectweb.asm.ClassWriter;
import jdk.internal.org.objectweb.asm.Opcodes;
import jdk.internal.org.objectweb.asm.tree.AbstractInsnNode;
import jdk.internal.org.objectweb.asm.tree.ClassNode;
import jdk.internal.org.objectweb.asm.tree.InsnNode;
import jdk.internal.org.objectweb.asm.tree.MethodInsnNode;
import jdk.internal.org.objectweb.asm.tree.MethodNode;
import jdk.internal.org.objectweb.asm.tree.TypeInsnNode;

public final class ComposeWindowPanelPatcher {
    private static final String SKIA = "androidx/compose/ui/awt/RenderSettings$SkiaSurface";
    private static final String SWING = "androidx/compose/ui/awt/RenderSettings$SwingGraphics";
    private static final String SETTINGS = "androidx/compose/ui/awt/RenderSettings";

    public static void main(String[] args) throws Exception {
        ClassNode clazz = new ClassNode();
        new ClassReader(Files.readAllBytes(Path.of(args[0]))).accept(clazz, 0);
        int replacements = 0;
        for (MethodNode method : clazz.methods) {
            List<AbstractInsnNode> insns = new ArrayList<>();
            for (AbstractInsnNode n = method.instructions.getFirst(); n != null; n = n.getNext()) {
                if (n.getOpcode() >= 0) insns.add(n);
            }
            for (int i = 0; i + 6 < insns.size(); i++) {
                AbstractInsnNode first = insns.get(i);
                if (!(first instanceof TypeInsnNode allocation)
                        || first.getOpcode() != Opcodes.NEW || !SKIA.equals(allocation.desc)
                        || !opcode(insns.get(i + 1), Opcodes.DUP)
                        || !opcode(insns.get(i + 2), Opcodes.ACONST_NULL)
                        || !opcode(insns.get(i + 3), Opcodes.ICONST_1)
                        || !opcode(insns.get(i + 4), Opcodes.ACONST_NULL)
                        || !(insns.get(i + 5) instanceof MethodInsnNode constructor)
                        || constructor.getOpcode() != Opcodes.INVOKESPECIAL
                        || !SKIA.equals(constructor.owner) || !"<init>".equals(constructor.name)
                        || !"(Ljava/lang/Boolean;ILkotlin/jvm/internal/DefaultConstructorMarker;)V".equals(constructor.desc)
                        || !(insns.get(i + 6) instanceof TypeInsnNode cast)
                        || cast.getOpcode() != Opcodes.CHECKCAST || !SETTINGS.equals(cast.desc)) continue;

                method.instructions.set(first, new TypeInsnNode(Opcodes.NEW, SWING));
                method.instructions.set(insns.get(i + 2),
                        new MethodInsnNode(Opcodes.INVOKESPECIAL, SWING, "<init>", "()V", false));
                for (int j = 3; j <= 6; j++) method.instructions.remove(insns.get(i + j));
                replacements++;
                i += 6;
            }
        }
        if (replacements != 1) {
            throw new IllegalStateException("expected exactly one SkiaSurface construction, found " + replacements);
        }
        ClassWriter writer = new ClassWriter(0);
        clazz.accept(writer);
        Files.write(Path.of(args[1]), writer.toByteArray());
    }

    private static boolean opcode(AbstractInsnNode node, int opcode) {
        return node instanceof InsnNode && node.getOpcode() == opcode;
    }
}
__TOOLBOX_PATCHER_SOURCE__

# ASM is internal to JDK 21 and earlier. Try installed JDKs until one can compile
# the deliberately small, version-specific patcher.
JDK_BIN=''
for JAVAC_CANDIDATE in "$(command -v javac 2>/dev/null || true)" /usr/lib/jvm/*/bin/javac; do
    test -n "$JAVAC_CANDIDATE" || continue
    test -x "$JAVAC_CANDIDATE" || continue
    CANDIDATE_BIN=$(CDPATH= cd -- "$(dirname -- "$JAVAC_CANDIDATE")" && pwd)
    test -x "$CANDIDATE_BIN/java" || continue
    test -x "$CANDIDATE_BIN/jar" || continue
    rm -rf "$WORK_DIR/patcher"
    mkdir -p "$WORK_DIR/patcher"
    if "$CANDIDATE_BIN/javac" \
            --add-exports java.base/jdk.internal.org.objectweb.asm=ALL-UNNAMED \
            --add-exports java.base/jdk.internal.org.objectweb.asm.tree=ALL-UNNAMED \
            -d "$WORK_DIR/patcher" "$WORK_DIR/ComposeWindowPanelPatcher.java" \
            >/dev/null 2>&1; then
        JDK_BIN=$CANDIDATE_BIN
        break
    fi
done
test -n "$JDK_BIN" || fail 'a full JDK 21 (for example jdk21-openjdk) is required to build the ASM patcher'

INPUT_CLASS="$WORK_DIR/classes/$CLASS_REL"
OUTPUT_CLASS="$INPUT_CLASS.patched"
"$JDK_BIN/java" \
    --add-exports java.base/jdk.internal.org.objectweb.asm=ALL-UNNAMED \
    --add-exports java.base/jdk.internal.org.objectweb.asm.tree=ALL-UNNAMED \
    -cp "$WORK_DIR/patcher" ComposeWindowPanelPatcher "$INPUT_CLASS" "$OUTPUT_CLASS"
mv "$OUTPUT_CLASS" "$INPUT_CLASS"

cp -p "$JAR_REL" "$WORK_DIR/ui-desktop.jar"
"$JDK_BIN/jar" uf "$WORK_DIR/ui-desktop.jar" -C "$WORK_DIR/classes" "$CLASS_REL"
unzip -t "$WORK_DIR/ui-desktop.jar" >/dev/null

"$JDK_BIN/javap" -classpath "$WORK_DIR/ui-desktop.jar" -c -p \
    androidx.compose.ui.awt.ComposeWindowPanel > "$WORK_DIR/bytecode.txt"
grep -q 'RenderSettings\$SwingGraphics."<init>":()V' "$WORK_DIR/bytecode.txt" \
    || fail 'patched SwingGraphics constructor was not found during verification'
if grep -q 'RenderSettings\$SkiaSurface."<init>' "$WORK_DIR/bytecode.txt"; then
    fail 'SkiaSurface construction remains after patching'
fi

cat > "$WORK_DIR/jetbrains-toolbox" <<'WRAPPER'
#!/bin/sh
set -eu

if [ -z "${WAYLAND_DISPLAY:-}" ]; then
    printf '%s\n' 'JetBrains Toolbox requires WAYLAND_DISPLAY for this native-Wayland build.' >&2
    exit 1
fi
case "$WAYLAND_DISPLAY" in
    /*) wayland_socket=$WAYLAND_DISPLAY ;;
    *)
        if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
            printf '%s\n' 'JetBrains Toolbox requires XDG_RUNTIME_DIR to locate the Wayland socket.' >&2
            exit 1
        fi
        wayland_socket=$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY
        ;;
esac
if [ ! -S "$wayland_socket" ]; then
    printf 'JetBrains Toolbox: Wayland socket is unavailable: %s\n' "$wayland_socket" >&2
    exit 1
fi

launcher_path=$(readlink -f -- "$0")
launcher_dir=$(CDPATH= cd -- "$(dirname -- "$launcher_path")" && pwd)
unset DISPLAY
if [ -n "${JAVA_TOOL_OPTIONS:-}" ]; then
    JAVA_TOOL_OPTIONS="$JAVA_TOOL_OPTIONS -Dawt.toolkit.name=WLToolkit"
else
    JAVA_TOOL_OPTIONS='-Dawt.toolkit.name=WLToolkit'
fi
export JAVA_TOOL_OPTIONS
exec "$launcher_dir/jetbrains-toolbox.vendor" "$@"
WRAPPER
chmod --reference=jetbrains-toolbox "$WORK_DIR/jetbrains-toolbox"
sh -n "$WORK_DIR/jetbrains-toolbox"

# Backups are written only after every generated artifact has passed validation.
cp -p jetbrains-toolbox jetbrains-toolbox.vendor
cp -p "$JAR_REL" "$JAR_REL.vendor"
if ! cp -p "$WORK_DIR/ui-desktop.jar" "$JAR_REL" \
        || ! cp -p "$WORK_DIR/jetbrains-toolbox" jetbrains-toolbox; then
    rollback
    fail 'installation failed; original files were restored'
fi

test -x jetbrains-toolbox
test -x jetbrains-toolbox.vendor
test -r "$JAR_REL"
printf '%s\n' "Installed the native Wayland patch for JetBrains Toolbox $TOOLBOX_VERSION."
printf '%s\n' 'Rollback: ./install-native-wayland.sh --rollback'
