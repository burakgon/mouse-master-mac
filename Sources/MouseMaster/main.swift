import AgentCore

// One executable, two roles: launchd starts it with --agent at login (the background agent
// that owns the mouse); without it, it is the settings window.
if CommandLine.arguments.contains("--agent") {
    AgentMain.run()
} else {
    MouseMasterApp.main()
}
