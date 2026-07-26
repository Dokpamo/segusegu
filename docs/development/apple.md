# Apple development

See `apps/apple/README.md`.

iOS and macOS use one Xcode workspace and project. The local `LorepiaKit` Swift
package shares the core client, feature state, tests, and reusable views.
Platform app targets retain their own root navigation, picker, lifecycle,
window, menu, and input behavior.

```bash
./scripts/build-apple.sh
```
