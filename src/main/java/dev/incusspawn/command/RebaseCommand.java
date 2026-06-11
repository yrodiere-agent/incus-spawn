package dev.incusspawn.command;

import dev.incusspawn.RuntimeServices;
import dev.incusspawn.config.BuildSource;
import dev.incusspawn.incus.IncusClient;
import dev.incusspawn.incus.Metadata;
import dev.incusspawn.lifecycle.InstanceLifecycle;
import dev.incusspawn.lifecycle.InstanceType;
import dev.incusspawn.tool.ToolDefLoader;
import dev.incusspawn.tool.ToolSetup;
import org.aesh.command.CommandDefinition;
import org.aesh.command.CommandResult;
import org.aesh.command.option.Argument;
import org.aesh.command.option.Option;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.TreeSet;
import java.util.stream.Collectors;

@CommandDefinition(
        name = "rebase",
        description = "Rebase an instance onto a freshly-rebuilt template",
        generateHelp = true
)
public class RebaseCommand extends BaseCommand {

    @Argument(description = "Instance to rebase", required = true)
    String name;

    @Option(name = "template", description = "Target template (defaults to instance's parent)")
    String template;

    @Option(name = "dry-run", description = "Show what would be done without making changes", hasValue = false)
    boolean dryRun;

    @Option(name = "yes", shortName = 'y', description = "Skip confirmation prompts", hasValue = false)
    boolean yes;

    private IncusClient incus;

    @Override
    protected CommandResult doExecute() throws Exception {
        this.incus = RuntimeServices.incus();

        // 1. Validate source instance
        if (!incus.exists(name)) {
            System.err.println("Error: instance '" + name + "' does not exist.");
            return CommandResult.valueOf(1);
        }
        var status = incus.getInstanceStatus(name);
        if (!"Stopped".equals(status)) {
            System.err.println("Error: instance '" + name + "' must be stopped before rebase.");
            System.err.println("Stop it first, then try again.");
            return CommandResult.valueOf(1);
        }
        var type = Metadata.getType(incus, name);
        if (!Metadata.TYPE_CLONE.equals(type)) {
            System.err.println("Error: '" + name + "' is not an instance (type: " + type + ").");
            return CommandResult.valueOf(1);
        }

        // 2. Resolve target template
        var targetTemplate = template != null ? template : incus.configGet(name, Metadata.PARENT);
        if (targetTemplate.isEmpty()) {
            System.err.println("Error: instance has no parent template. Use --template to specify one.");
            return CommandResult.valueOf(1);
        }
        if (!incus.exists(targetTemplate)) {
            System.err.println("Error: template '" + targetTemplate + "' does not exist. Build it first.");
            return CommandResult.valueOf(1);
        }

        // 3. Collect preserve paths from all tools in the template
        var toolDefLoader = new ToolDefLoader();
        var toolSetups = RuntimeServices.toolSetups();
        var targetBuildSource = BuildSource.fromJson(
                incus.configGet(targetTemplate, Metadata.BUILD_SOURCE));
        if (targetBuildSource != null) {
            toolDefLoader.addFallbacks(targetBuildSource.getTools());
        }
        var preservePaths = collectPreservePaths(targetBuildSource, toolDefLoader, toolSetups);

        // 4. Read metadata to carry over from the source (while it's stopped)
        var sourceNetworkMode = incus.configGet(name, Metadata.NETWORK_MODE);
        var sourceGuiEnabled = incus.configGet(name, Metadata.GUI_ENABLED);
        var sourceWorkdir = incus.configGet(name, Metadata.WORKDIR);
        var sourceShellCommand = incus.configGet(name, Metadata.SHELL_COMMAND);

        // 5. Create the rebase target from the template
        var tempName = name + "-rebasing";
        incus.deleteIfExists(tempName);
        System.out.println("Creating fresh branch from '" + targetTemplate + "'...");
        incus.copy(targetTemplate, tempName);

        InstanceLifecycle.tagMetadata(incus, tempName, Metadata.TYPE_CLONE, targetTemplate);
        InstanceLifecycle.integrateWithHost(incus, tempName, InstanceType.INSTANCE);

        // 6. Start both containers
        System.out.println("Starting containers for state transfer...");
        incus.start(name);
        incus.waitForSystemd(name);
        incus.start(tempName);
        incus.waitForSystemd(tempName);

        try {
            // 7. Snapshot clean home directory from the target
            var cleanHomeFiles = listHomeFiles(tempName);

            // 8. Detect manually-installed packages
            var manualPackages = detectManualPackages(name, targetBuildSource);

            // 9. Detect user-created files in home directory
            var sourceHomeFiles = listHomeFiles(name);
            var userFiles = diffHomeFiles(sourceHomeFiles, cleanHomeFiles, preservePaths);

            // 10. Print summary
            printSummary(preservePaths, manualPackages, userFiles);

            if (dryRun) {
                System.out.println("\nDry run — no changes made.");
                incus.stop(name);
                incus.stop(tempName);
                incus.delete(tempName, true);
                return CommandResult.SUCCESS;
            }

            // 11. Transfer tool-preserved paths
            if (!preservePaths.isEmpty()) {
                System.out.println("Transferring preserved tool state...");
                transferPaths(name, tempName, new ArrayList<>(preservePaths));
            }

            // 12. Transfer user-created home directory files
            if (!userFiles.isEmpty()) {
                System.out.println("Transferring user files...");
                transferPaths(name, tempName, userFiles);
            }

            // 13. Fix ownership of home directory
            incus.shellExec(tempName, "chown", "-R", "agentuser:agentuser", "/home/agentuser");

            // 14. Re-install manually-installed packages
            if (!manualPackages.isEmpty()) {
                System.out.println("Re-installing " + manualPackages.size()
                        + " manually-installed packages...");
                var installCmd = new ArrayList<>(List.of("dnf", "install", "-y", "--skip-unavailable"));
                installCmd.addAll(manualPackages);
                incus.shellExecInteractive(tempName, installCmd.toArray(String[]::new));
            }

            // 15. Carry over metadata from source
            if (!sourceNetworkMode.isEmpty()) {
                incus.configSet(tempName, Metadata.NETWORK_MODE, sourceNetworkMode);
            }
            if (!sourceGuiEnabled.isEmpty()) {
                incus.configSet(tempName, Metadata.GUI_ENABLED, sourceGuiEnabled);
            }
            if (!sourceWorkdir.isEmpty()) {
                incus.configSet(tempName, Metadata.WORKDIR, sourceWorkdir);
            }
            if (!sourceShellCommand.isEmpty()) {
                incus.configSet(tempName, Metadata.SHELL_COMMAND, sourceShellCommand);
            }
        } catch (Exception e) {
            System.err.println("Error during rebase: " + e.getMessage());
            System.err.println("Cleaning up temporary instance...");
            try { incus.stop(name); } catch (Exception ignored) {}
            try { incus.stop(tempName); } catch (Exception ignored) {}
            incus.delete(tempName, true);
            return CommandResult.valueOf(1);
        }

        // 16. Stop both and swap names
        System.out.println("Finalizing...");
        incus.stop(name);
        incus.stop(tempName);

        var backupName = name + "-pre-rebase";
        incus.deleteIfExists(backupName);
        incus.rename(name, backupName);
        incus.rename(tempName, name);

        System.out.println("Rebase complete. Old instance saved as '" + backupName + "'.");
        System.out.println("Delete it when satisfied: isx destroy " + backupName);
        return CommandResult.SUCCESS;
    }

    private Set<String> collectPreservePaths(BuildSource buildSource,
                                              ToolDefLoader toolDefLoader,
                                              List<ToolSetup> cdiToolSetups) {
        var paths = new LinkedHashSet<String>();
        if (buildSource == null) return paths;

        for (var toolName : buildSource.getTools().keySet()) {
            var toolSetup = findTool(toolName, toolDefLoader, cdiToolSetups);
            if (toolSetup != null) {
                for (var p : toolSetup.preserve()) {
                    paths.add(expandHome(p));
                }
            }
        }
        // Also check CDI tools that may not have YAML definitions
        if (buildSource.getToolInstances() != null) {
            for (var entry : buildSource.getToolInstances().entrySet()) {
                if (buildSource.getTools().containsKey(entry.getKey())) continue;
                var toolSetup = findTool(entry.getKey(), toolDefLoader, cdiToolSetups);
                if (toolSetup != null) {
                    for (var p : toolSetup.preserve()) {
                        paths.add(expandHome(p));
                    }
                }
            }
        }
        return paths;
    }

    private static ToolSetup findTool(String name, ToolDefLoader toolDefLoader,
                                       Iterable<ToolSetup> cdiTools) {
        var tool = toolDefLoader.find(name);
        if (tool != null) return tool;
        for (var t : cdiTools) {
            if (t.name().equals(name)) return t;
        }
        return null;
    }

    private static String expandHome(String path) {
        if (path.startsWith("~/")) {
            return "/home/agentuser/" + path.substring(2);
        }
        if (path.equals("~")) {
            return "/home/agentuser";
        }
        return path;
    }

    private Set<String> listHomeFiles(String container) {
        var result = incus.shellExec(container, "sh", "-c",
                "find /home/agentuser -maxdepth 2 "
                        + "-not -path '/home/agentuser/.cache/*' "
                        + "-not -path '/home/agentuser/.local/share/claude/versions/*' "
                        + "-not -path '/home/agentuser/.local/state/*' "
                        + "2>/dev/null | sort");
        return new TreeSet<>(result.stdout().lines()
                .filter(l -> !l.isBlank())
                .collect(Collectors.toSet()));
    }

    private Set<String> detectManualPackages(String container, BuildSource buildSource) {
        var result = incus.shellExec(container, "sh", "-c",
                "dnf repoquery --installed --userinstalled --qf '%{name}' 2>/dev/null"
                        + " || rpm -qa --qf '%{NAME}\\n'");
        var userInstalled = new TreeSet<>(result.stdout().lines()
                .filter(l -> !l.isBlank())
                .collect(Collectors.toSet()));

        // Collect all declared packages from template image defs + tool defs
        var declared = new TreeSet<String>();
        if (buildSource != null) {
            for (var imgDef : buildSource.getDefinitions().values()) {
                if (imgDef.getPackages() != null) {
                    declared.addAll(imgDef.getPackages());
                }
            }
            for (var toolDef : buildSource.getTools().values()) {
                if (toolDef.getPackages() != null) {
                    declared.addAll(toolDef.getPackages());
                }
            }
        }

        userInstalled.removeAll(declared);
        // Remove well-known base packages that are always present
        userInstalled.removeAll(Set.of(
                "basesystem", "bash", "coreutils", "dnf", "dnf5", "fedora-release",
                "filesystem", "glibc", "glibc-common", "glibc-minimal-langpack",
                "kernel-core", "rpm", "setup", "shadow-utils", "systemd", "util-linux",
                "sudo", "git", "curl", "which", "procps-ng", "findutils", "tar",
                "gzip", "xz", "bzip2", "sed", "grep", "gawk"
        ));
        return userInstalled;
    }

    private List<String> diffHomeFiles(Set<String> sourceFiles, Set<String> cleanFiles,
                                        Set<String> preservePaths) {
        var userFiles = new ArrayList<String>();
        for (var file : sourceFiles) {
            if (cleanFiles.contains(file)) continue;
            if (file.equals("/home/agentuser")) continue;
            boolean coveredByPreserve = preservePaths.stream()
                    .anyMatch(p -> file.startsWith(p + "/") || file.equals(p));
            if (!coveredByPreserve) {
                userFiles.add(file);
            }
        }
        // Collapse to top-level entries: if we have /home/agentuser/work and
        // /home/agentuser/work/foo, only keep /home/agentuser/work
        var collapsed = new ArrayList<String>();
        for (var file : userFiles) {
            boolean isChild = userFiles.stream()
                    .anyMatch(other -> !other.equals(file) && file.startsWith(other + "/"));
            if (!isChild) {
                collapsed.add(file);
            }
        }
        return collapsed;
    }

    private void printSummary(Set<String> preservePaths, Set<String> manualPackages,
                               List<String> userFiles) {
        System.out.println();
        System.out.println("=== Rebase Summary ===");
        System.out.println();

        if (!preservePaths.isEmpty()) {
            System.out.println("Tool-preserved paths:");
            for (var p : preservePaths) {
                System.out.println("  " + p);
            }
            System.out.println();
        }

        if (!manualPackages.isEmpty()) {
            System.out.println("Manually-installed packages to re-install:");
            for (var p : manualPackages) {
                System.out.println("  " + p);
            }
            System.out.println();
        }

        if (!userFiles.isEmpty()) {
            System.out.println("User-created files/directories to transfer:");
            for (var f : userFiles) {
                System.out.println("  " + f);
            }
            System.out.println();
        }

        if (preservePaths.isEmpty() && manualPackages.isEmpty() && userFiles.isEmpty()) {
            System.out.println("Nothing to transfer — the instance has no user state.");
            System.out.println();
        }
    }

    private void transferPaths(String source, String target, List<String> paths)
            throws IOException {
        if (paths.isEmpty()) return;

        // Filter to paths that actually exist in the source container
        var existCheck = incus.shellExec(source, "sh", "-c",
                paths.stream()
                        .map(p -> "[ -e " + shellQuote(p) + " ] && echo " + shellQuote(p))
                        .collect(Collectors.joining("; ")));
        var existingPaths = existCheck.stdout().lines()
                .filter(l -> !l.isBlank())
                .toList();
        if (existingPaths.isEmpty()) return;

        var archivePath = "/tmp/isx-rebase-transfer.tar.gz";

        // Create tar archive in source container (paths relative to /)
        var tarArgs = existingPaths.stream()
                .map(p -> p.startsWith("/") ? p.substring(1) : p)
                .map(RebaseCommand::shellQuote)
                .collect(Collectors.joining(" "));
        incus.shellExec(source, "sh", "-c",
                "tar czf " + archivePath + " -C / " + tarArgs + " 2>/dev/null; true");

        // Pull archive to host via REST API
        var archiveBytes = incus.filePull(source, archivePath);

        // Push to target and extract
        var tempFile = Files.createTempFile("isx-rebase-", ".tar.gz");
        try {
            Files.write(tempFile, archiveBytes);
            incus.filePush(tempFile.toString(), target, archivePath);
        } finally {
            Files.deleteIfExists(tempFile);
        }

        incus.shellExec(target, "sh", "-c",
                "tar xzf " + archivePath + " -C / && rm -f " + archivePath);

        // Clean up source
        incus.shellExec(source, "rm", "-f", archivePath);
    }

    static String shellQuote(String s) {
        return "'" + s.replace("'", "'\\''") + "'";
    }
}
