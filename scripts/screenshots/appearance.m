// Тема для копии SEOpars при съёмке скриншотов, без смены системной темы.
// Подгружается через DYLD_INSERT_LIBRARIES только в копию из scripts/render-screenshots.sh:
// SEOPARS_APPEARANCE=dark|light задаёт NSApp.appearance до появления окна.
// macOS 27 не учитывает для этого ни -AppleInterfaceStyle в аргументах, ни домен приложения.
#import <AppKit/AppKit.h>

__attribute__((constructor)) static void seopars_screenshot_appearance(void) {
    const char *value = getenv("SEOPARS_APPEARANCE");
    if (value == NULL) return;
    NSAppearanceName name = strcmp(value, "dark") == 0 ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua;
    [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationWillFinishLaunchingNotification
                                                      object:nil
                                                       queue:nil
                                                  usingBlock:^(NSNotification *note) {
        NSApp.appearance = [NSAppearance appearanceNamed:name];
    }];
}
