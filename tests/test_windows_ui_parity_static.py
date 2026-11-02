"""Windows WPF feature-parity and interaction contracts; XAML is parsed, not rendered."""
from pathlib import Path
import re
import unittest
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
UI = ROOT / "windows/SwitcherUI.ps1"


X_NAME = "{http://schemas.microsoft.com/winfx/2006/xaml}Name"


def local_name(node):
    return node.tag.rsplit("}", 1)[-1]


def find_named(root, name):
    matches = [node for node in root.iter() if node.get(X_NAME) == name]
    if len(matches) != 1:
        raise AssertionError(f"expected one x:Name={name}, found {len(matches)}")
    return matches[0]


def setter(style, property_name):
    return next(
        (node for node in style if local_name(node) == "Setter" and node.get("Property") == property_name),
        None,
    )


def common_container(root, nodes):
    parents = {child: parent for parent in root.iter() for child in parent}
    candidate = parents[nodes[0]]
    while candidate is not root:
        if all(node in set(candidate.iter()) for node in nodes):
            return candidate
        candidate = parents[candidate]
    raise AssertionError("controls do not share a layout container")


def nearest_ancestor(root, node, tag_name):
    parents = {child: parent for parent in root.iter() for child in parent}
    while node in parents:
        node = parents[node]
        if local_name(node) == tag_name:
            return node
    raise AssertionError(f"missing {tag_name} ancestor")


class WindowsUiParityStaticTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ui = UI.read_text(encoding="utf-8-sig")
        cls.windows = {}
        for variable in ("xaml", "toolsXaml", "inputXaml", "dialogXaml", "settingsXaml"):
            match = re.search(rf'\${variable} = @"\n(.*?)\n"@', cls.ui, re.S)
            if match is None:
                raise AssertionError(f"missing {variable} XAML here-string")
            cls.windows[variable] = ET.fromstring(match.group(1))
        cls.xaml = re.search(r'\$xaml = @"\n(.*?)\n"@', cls.ui, re.S).group(1)
        cls.root = cls.windows["xaml"]

    def test_every_xaml_window_is_well_formed_and_names_are_unique(self):
        for variable, root in self.windows.items():
            with self.subTest(window=variable):
                names = [node.get(X_NAME) for node in root.iter() if node.get(X_NAME)]
                self.assertEqual(len(names), len(set(names)))

    def test_main_controls_keep_live_references_and_event_bindings(self):
        for name in (
            "StatusPill", "StatusText", "CheckList", "ProxyClient", "CurrentAccount",
            "UpdateBar", "UpdateText", "BtnUpdate", "BtnLater", "Banner",
            "BtnFix", "BtnRefresh", "BtnDiagnostics", "BtnCheckUpdate", "BtnTools", "BtnSettings",
        ):
            with self.subTest(control=name):
                find_named(self.root, name)
        for name in (
            "StatusText", "CheckList", "ProxyClient", "CurrentAccount", "UpdateBar", "UpdateText",
            "BtnUpdate", "BtnLater", "Banner", "BtnFix", "BtnRefresh", "BtnDiagnostics",
            "BtnCheckUpdate", "BtnTools", "BtnSettings",
        ):
            with self.subTest(reference=name):
                self.assertRegex(self.ui, rf"\$win\.FindName\('{name}'\)")
        for name in (
            "BtnFix", "BtnRefresh", "BtnDiagnostics", "BtnCheckUpdate", "BtnTools", "BtnSettings",
            "BtnUpdate", "BtnLater",
        ):
            with self.subTest(event=name):
                self.assertRegex(self.ui, rf"\$win\.FindName\('{name}'\)\.Add_Click")
        self.assertRegex(self.ui, r"\$win\.FindName\('ProxyClient'\)\.Add_SelectionChanged")
        self.assertIn("$win.FindName('CheckList').ItemsSource", self.ui)
        for binding in ("Name", "Detail", "StateText", "Color"):
            self.assertIn(f"{{Binding {binding}}}", self.xaml)

    def test_four_account_cards_keep_metadata_and_switch_handlers(self):
        buttons = [find_named(self.root, f"Btn{slot}") for slot in "ABCD"]
        accounts = common_container(self.root, buttons)
        self.assertIn(local_name(accounts), {"Grid", "UniformGrid"})
        for slot, button in zip("ABCD", buttons):
            with self.subTest(slot=slot):
                self.assertEqual(local_name(button), "Button")
                find_named(button, f"Account{slot}Subtitle")
                self.assertIsNone(button.get("Width"), "account cards must share available width")
                self.assertIsNotNone(button.get("Style"), "account cards need a shared visual style")
        self.assertRegex(self.ui, r"\$win\.FindName\(\"Btn\$slot\"\)\.Add_Click")
        for text in ("fields['current']", "fields['accounts']", 'fields["acc$slot"]', "未初始化", "已建档"):
            self.assertIn(text, self.ui)

    def test_status_and_proxy_cards_contain_their_live_controls(self):
        status_card = nearest_ancestor(self.root, find_named(self.root, "StatusText"), "Border")
        while status_card.get("BorderBrush") is None and status_card.get("Style") is None:
            status_card = nearest_ancestor(self.root, status_card, "Border")
        proxy = find_named(self.root, "ProxyClient")
        proxy_card = nearest_ancestor(self.root, proxy, "Border")
        for card in (status_card, proxy_card):
            self.assertTrue(
                card.get("Style") or all(card.get(name) for name in ("Background", "BorderBrush", "CornerRadius")),
                "status and proxy regions must retain card styling",
            )
        self.assertEqual(local_name(proxy), "ComboBox")
        modes = {
            item.get("Tag")
            for item in proxy.iter()
            if local_name(item) == "ComboBoxItem"
        }
        self.assertEqual(
            modes,
            {"clash-verge", "flclash", "sing-box", "clashx", "surge", "wireguard", "other", "auto"},
        )

    def test_navigation_is_structural_and_keeps_tools_and_settings(self):
        tools = find_named(self.root, "BtnTools")
        settings = find_named(self.root, "BtnSettings")
        navigation = common_container(self.root, [tools, settings])
        self.assertIn(local_name(navigation), {"Grid", "StackPanel"})
        self.assertIn("Show-ToolsWindow", self.ui)
        self.assertIn("Show-CheckSettings", self.ui)
        for name in ("BtnFingerprint", "BtnCliInfo", "BtnOpenSafe", "BtnRegion", "BtnSnapshotExport", "BtnSnapshotImport"):
            find_named(self.windows["toolsXaml"], name)
            self.assertRegex(self.ui, rf"\$toolWin\.FindName\('{name}'\)\.Add_Click")
        for command in ("fingerprint", "cli-info", "open-safe", "set-region", "snapshot-export", "snapshot-import"):
            self.assertIn(command, self.ui)

    def test_main_layout_remains_scrollable_and_adapts_account_columns(self):
        self.assertEqual(self.root.get("ResizeMode"), "CanResize")
        self.assertGreaterEqual(float(self.root.get("MinWidth")), 480)
        self.assertIsNotNone(self.root.get("MinHeight"))
        scrollers = [node for node in self.root.iter() if local_name(node) == "ScrollViewer"]
        self.assertTrue(scrollers, "content must remain reachable when the update bar expands")
        self.assertTrue(any(node.get("HorizontalScrollBarVisibility") == "Disabled" for node in scrollers))
        accounts = common_container(self.root, [find_named(self.root, f"Btn{slot}") for slot in "ABCD"])
        account_name = accounts.get(X_NAME)
        self.assertIsNotNone(account_name, "responsive account layout needs a named container")
        self.assertRegex(self.ui, r"(?:Add_SizeChanged|SizeChanged\s*=)")
        resize = self.ui[self.ui.index("SizeChanged"):]
        self.assertIn(account_name, resize)
        self.assertRegex(resize, r"(?:ColumnDefinitions|\.Columns)")

    def test_dark_theme_uses_reusable_professional_control_styles(self):
        background = self.root.get("Background", "")
        match = re.fullmatch(r"#(?:[0-9A-Fa-f]{2})?([0-9A-Fa-f]{6})", background)
        self.assertIsNotNone(match, "window needs an opaque dark background")
        red, green, blue = (int(match.group(1)[i:i + 2], 16) / 255 for i in (0, 2, 4))
        luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        self.assertLess(luminance, 0.2)
        styles = [node for node in self.root.iter() if local_name(node) == "Style"]
        buttons = [style for style in styles if style.get("TargetType") == "Button" and style.get("{http://schemas.microsoft.com/winfx/2006/xaml}Key") is None]
        self.assertTrue(buttons)
        min_height = setter(buttons[0], "MinHeight")
        self.assertIsNotNone(min_height)
        self.assertGreaterEqual(float(min_height.get("Value")), 36)
        accent = next((style for style in styles if style.get("{http://schemas.microsoft.com/winfx/2006/xaml}Key") == "AccentButton"), None)
        self.assertIsNotNone(accent)
        self.assertIn("StaticResource", accent.get("BasedOn", ""))
        account_style = find_named(self.root, "BtnA").get("Style", "")
        self.assertIn("StaticResource", account_style)

    def test_long_operations_are_serialized_and_audited(self):
        self.assertIn("Start-Job", self.ui)
        self.assertIn("DispatcherTimer", self.ui)
        self.assertIn("$script:isBusy", self.ui)
        self.assertIn("$script:environmentReady", self.ui)
        self.assertIn("Add_Closing", self.ui)
        self.assertIn("$_.Cancel = $true", self.ui)
        switch = self.ui[self.ui.index("function Switch-To"):]
        switch = switch[:switch.index("\nfunction ")]
        self.assertIn("environmentReady", switch)
        self.assertIn("$script:pendingSwitch = $target", switch)
        self.assertLess(switch.index("$script:pendingSwitch = $target"), switch.index("Refresh-Checks"))
        complete = self.ui[self.ui.index("function Complete-UiOperation"):]
        self.assertIn("$script:pendingSwitch", complete)

    def test_snapshot_passwords_use_stdin_not_arguments(self):
        self.assertIn("PasswordBox", self.ui)
        self.assertIn("--password-stdin", self.ui)
        self.assertIn("StandardInput", self.ui)
        self.assertNotRegex(self.ui, r"snapshot-(?:export|import)[^\n]*Password")

    def test_set_status_updates_the_icon_text_and_pill_visuals(self):
        icon = find_named(self.root, "StatusIcon")
        self.assertEqual(local_name(icon), "TextBlock")
        find_named(self.root, "StatusPill")
        start = self.ui.index("function Set-Status")
        end = self.ui.index("\nfunction ", start + 1)
        set_status = self.ui[start:end]
        for control, properties in (
            ("StatusText", {"Text", "Foreground"}),
            ("StatusIcon", {"Text", "Foreground"}),
            ("StatusPill", {"Background"}),
        ):
            for property_name in properties:
                with self.subTest(control=control, property=property_name):
                    self.assertRegex(
                        set_status,
                        rf"\$win\.FindName\('{control}'\)\.{property_name}\s*=",
                    )

    def test_compact_layout_also_adapts_the_sidebar_and_header(self):
        sidebar = nearest_ancestor(self.root, find_named(self.root, "NavigationPanel"), "Border")
        header = common_container(
            self.root,
            [find_named(self.root, name) for name in ("CurrentAccount", "BtnRefresh", "BtnFix")],
        )
        sidebar_name = sidebar.get(X_NAME)
        header_name = header.get(X_NAME)
        self.assertIsNotNone(sidebar_name, "the responsive sidebar needs a live reference")
        self.assertIsNotNone(header_name, "the responsive header needs a live reference")
        start = self.ui.index("$win.Add_SizeChanged")
        end = self.ui.index("\n$win.Add_ContentRendered", start)
        resize = self.ui[start:end]
        self.assertIn(sidebar_name, resize)
        self.assertIn(header_name, resize)
        self.assertRegex(resize, r"(?:\.Width|\.Visibility|ColumnDefinitions)")
        self.assertRegex(resize, r"(?:RowDefinitions|::SetRow|\.Orientation)")

    def test_current_account_is_accent_blue_and_other_accounts_keep_card_color(self):
        styles = [node for node in self.root.iter() if local_name(node) == "Style"]
        x_key = "{http://schemas.microsoft.com/winfx/2006/xaml}Key"
        account_style = next(style for style in styles if style.get(x_key) == "AccountButton")
        accent_style = next(style for style in styles if style.get(x_key) == "AccentButton")
        card_background = setter(account_style, "Background").get("Value")
        accent_background = setter(accent_style, "Background").get("Value")
        start = self.ui.index("function Apply-StatusOutput")
        end = self.ui.index("\nfunction ", start + 1)
        apply_status = self.ui[start:end]
        match = re.search(
            r"\$win\.FindName\(\"Btn\$slot\"\)\.Background\s*=\s*"
            r"if \(\$current -eq \$slot\) \{ '([^']+)' \} else \{ '([^']+)' \}",
            apply_status,
        )
        self.assertIsNotNone(match, "status refresh must restyle both current and non-current cards")
        current_background, other_background = match.groups()
        self.assertEqual(current_background, accent_background)
        self.assertEqual(other_background, card_background)

    def test_keyboard_focus_has_a_visible_button_border_trigger(self):
        styles = [node for node in self.root.iter() if local_name(node) == "Style"]
        default_button = next(
            style for style in styles
            if style.get("TargetType") == "Button"
            and style.get("{http://schemas.microsoft.com/winfx/2006/xaml}Key") is None
        )
        triggers = [
            node for node in default_button.iter()
            if local_name(node) == "Trigger"
            and node.get("Property") == "IsKeyboardFocused"
            and node.get("Value") == "True"
        ]
        self.assertTrue(triggers, "keyboard users need a focus indicator, not only hover feedback")
        focus_setters = [
            node for trigger in triggers for node in trigger
            if local_name(node) == "Setter"
            and node.get("TargetName") == "ButtonBorder"
            and node.get("Property") in {"BorderBrush", "BorderThickness"}
            and node.get("Value") not in {None, "", "Transparent", "0"}
        ]
        self.assertTrue(focus_setters, "keyboard focus must visibly change the button border")

    def test_states_remain_semantic(self):
        self.assertRegex(self.ui, r"'skip'\s*\{")
        self.assertIn("#FF6B7280", self.ui)
        self.assertIn("IsEnabled = $false", self.ui)
        self.assertIn("ToolTip", self.xaml)


if __name__ == "__main__":
    unittest.main()
