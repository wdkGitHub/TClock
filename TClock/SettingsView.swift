import SwiftUI

/// 设置面板：单页扁平表单，不分类、不加分组标题。
///
/// - 去掉 `TabView` 与 `Section` 标题，所有可选项一屏纵向排布，减少跳转；
/// - 字号用语义字号，卡片描边 / 圆角 / 阴影 / 间距走 `AppTheme` token；
/// - 说明文字压缩到必要的三行，其余靠 `.help` 悬浮提示；
/// - 所有改动依旧即时生效并持久化（由 `AppSettings` 负责）。
struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    /// 表单右侧控件的统一宽度。
    private let controlWidth: CGFloat = AppTheme.Metrics.controlWidth

    var body: some View {
        Form {
            Section {
                formatRows
                preview
                    .frame(maxWidth: .infinity)
                appearanceRows
                behaviorRows
            }
        }
        .formStyle(.grouped)
        .frame(
            minWidth: AppTheme.Metrics.settingsMinWidth,
            minHeight: AppTheme.Metrics.settingsMinHeight
        )
    }

    // MARK: - 日期 / 时间格式

    private var formatRows: some View {
        Group {
            // 日期：显隐与格式是两个独立控件；隐藏时格式输入置灰。
            LabeledContent("settings.date.label") {
                HStack(spacing: AppTheme.Space.sm) {
                    // 占位符留空：macOS 的 roundedBorder TextField 在定宽下会把较长占位符
                    // 溢出绘制到输入框右侧，看起来像重复了两份格式串。
                    TextField("", text: $settings.datePattern)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .frame(width: controlWidth - 40)
                        .help("settings.date.help")

                    dateMenu
                }
            }
            .disabled(!settings.showDate)

            // 时间只有 24 / 12 小时制两种，不再允许自由输入格式串。
            LabeledContent("settings.time.hourCycle") {
                Picker("settings.time.hourCycle", selection: $settings.hourCycle) {
                    ForEach(HourCycle.allCases) { cycle in
                        Text(cycle.display).tag(cycle)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: controlWidth)
            }

            HStack(spacing: AppTheme.Space.xl) {
                Toggle("settings.date.show", isOn: $settings.showDate)
                    .toggleStyle(.checkbox)
                    .fixedSize()

                Toggle("settings.time.showWeekday", isOn: $settings.showWeekday)
                    .toggleStyle(.checkbox)
                    .fixedSize()
                    .help("settings.time.showWeekday.help")

                Spacer(minLength: 0)
            }

            HStack(spacing: AppTheme.Space.xl) {
                // 上下午开关始终可见可设置；24 小时制下没有上下午概念，置灰但保留状态。
                Toggle("settings.time.showAMPM", isOn: $settings.showAMPM)
                    .toggleStyle(.checkbox)
                    .fixedSize()
                    .disabled(settings.hourCycle != .twelve)
                    .help("settings.time.showAMPM.help")

                Toggle("settings.format.blink", isOn: $settings.blinkSeparator)
                    .toggleStyle(.checkbox)
                    .fixedSize()

                Spacer(minLength: 0)
            }
        }
    }

    /// 日期格式预设：右侧图标按钮，菜单里是只含年月日的常用格式。
    private var dateMenu: some View {
        Menu {
            ForEach(DateFormatPreset.all) { preset in
                Button {
                    settings.datePattern = preset.pattern
                } label: {
                    Text("\(preset.title)　\(preset.pattern)")
                }
            }
        } label: {
            Image(systemName: "calendar")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("settings.date.menu.help")
        .accessibilityLabel("settings.date.menu.label")
    }

    // MARK: - 外观

    private var appearanceRows: some View {
        Group {
            LabeledContent("settings.language.label") {
                Picker("settings.language.label", selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.display).tag(language)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: controlWidth)
                .onChange(of: settings.language) { _, newValue in
                    LanguageManager.apply(newValue)
                }
            }
            .help("settings.language.help")

            LabeledContent("settings.appearance.theme") {
                Picker("settings.appearance.theme", selection: $settings.appearanceMode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.display).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: controlWidth)
            }

            Text("settings.appearance.theme.help")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LabeledContent("settings.appearance.font") {
                Picker("settings.appearance.font", selection: $settings.fontFamily) {
                    Text("settings.appearance.font.system").tag(FontCatalog.systemFamily)
                    ForEach(FontCatalog.allFamilies, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: controlWidth)
            }

            LabeledContent("settings.appearance.size") {
                HStack(spacing: AppTheme.Space.sm) {
                    Slider(value: $settings.fontSize, in: 20...320)

                    Text("\(Int(settings.fontSize))")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
                .frame(width: controlWidth + 40)
            }

            LabeledContent("settings.appearance.weight") {
                Picker("settings.appearance.weight", selection: $settings.fontWeight) {
                    ForEach(FontWeightOption.allCases) { weight in
                        Text(weight.display).tag(weight)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            LabeledContent("settings.appearance.color") {
                ColorPicker("settings.appearance.color", selection: colorBinding, supportsOpacity: false)
                    .labelsHidden()
            }

            Toggle("settings.appearance.shadow", isOn: $settings.shadowEnabled)
                .toggleStyle(.checkbox)
                .help("settings.appearance.shadow.help")

            LabeledContent("settings.appearance.opacity") {
                HStack(spacing: AppTheme.Space.sm) {
                    Slider(value: $settings.opacity, in: 0.1...1)

                    Text(settings.opacity.formatted(.percent.precision(.fractionLength(0))))
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
                .frame(width: controlWidth + 40)
            }
            .help("settings.appearance.opacity.help")
        }
    }

    /// 预览卡形状：圆角只定义一次，填充 / 裁剪 / 描边共用。
    private var previewShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous)
    }

    /// 预览区：系统材质底 + 与文字亮度相反的配色，任何文字颜色都看得清。
    /// 阴影只加在「卡片」上，时钟文字作为外层 overlay 叠上来，不会被二次投影。
    private var preview: some View {
        let isLightText = (settings.textColor.usingColorSpace(.sRGB)?.brightnessComponent ?? 1) > 0.6
        let shadow = AppTheme.Shadow.card

        let card = previewShape
            .fill(.regularMaterial)
            .environment(\.colorScheme, isLightText ? .dark : .light)
            .frame(height: AppTheme.Metrics.previewHeight)
            .overlay {
                previewShape.strokeBorder(AppTheme.Palette.borderDefault, lineWidth: 1)
            }
            .clipShape(previewShape)
            .shadow(color: shadow.color, radius: shadow.radius, x: shadow.x, y: shadow.y)

        return card
            .overlay {
                ClockView(scale: previewScale)
                    .environmentObject(settings)
                    .padding(.horizontal, AppTheme.Space.sm)
            }
            .accessibilityLabel("settings.preview.label")
    }

    /// 让预览文字稳定落在约 32pt 高度内。
    private var previewScale: CGFloat {
        min(0.5, AppTheme.Metrics.previewScaleTarget / max(12, CGFloat(settings.fontSize)))
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { Color(nsColor: settings.textColor) },
            set: { settings.textColor = NSColor($0) }
        )
    }

    // MARK: - 窗口与位置

    private var behaviorRows: some View {
        Group {
            Toggle(isOn: $settings.isLocked) {
                Text("settings.behavior.lock")
            }
            .toggleStyle(.switch)
            .help("settings.behavior.lock.help")

            Toggle("settings.behavior.alwaysOnTop", isOn: $settings.alwaysOnTop)
                .toggleStyle(.switch)
                .help("settings.behavior.alwaysOnTop.help")

            LabeledContent("common.presetPosition") {
                HStack(spacing: AppTheme.Space.sm) {
                    ForEach(ClockCorner.allCases) { corner in
                        Button(corner.display) { applyCorner(corner) }
                            .buttonStyle(.bordered)
                    }
                }
            }
            .help("settings.behavior.corner.help")

            LabeledContent("settings.behavior.currentPosition") {
                Text(positionText)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Button("settings.behavior.reset") {
                NotificationCenter.default.post(name: .tclockResetPosition, object: nil)
            }
            .help("settings.behavior.reset.help")
        }
    }

    /// 预设角落通过通知交给 `MainWindowManager`，SwiftUI 不直接持有窗口对象。
    private func applyCorner(_ corner: ClockCorner) {
        NotificationCenter.default.post(
            name: .tclockApplyCorner,
            object: nil,
            userInfo: ["corner": corner.rawValue]
        )
    }

    private var positionText: String {
        settings.hasOrigin
            ? String(format: "x %.0f , y %.0f", settings.originX, settings.originY)
            : NSLocalizedString("common.defaultPosition", comment: "")
    }
}
