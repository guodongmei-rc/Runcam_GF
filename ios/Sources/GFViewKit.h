#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Gyroflow 模块 View 工具：通用控件工厂 + 主题应用器。
// 色值来自 GFTheme，本类只负责把视图生产出来 / 把视图调成主题外观。
@interface GFViewKit : NSObject

// 主按钮：橙底白字 R10，contentEdgeInsets 10/16
+ (UIButton *)primaryButtonWithTitle:(NSString *)title;

// 方框 checkbox UIButton（24×24，未选/选中描边粗细一致，白色 tint）
// target/action 任一为 nil 时跳过 addTarget。
+ (UIButton *)makeCheckbox;
+ (UIButton *)makeCheckboxWithTarget:(nullable id)target action:(nullable SEL)action;

// checkbox 图像（pointSize 20 + WeightRegular，给两态保证描边粗细 1:1）
+ (UIImage *)checkboxImageChecked:(BOOL)checked;

// 主题应用器 —— 把现有视图调成 GF 主题外观
+ (void)applyToSlider:(UISlider *)slider;
+ (void)applyToSwitch:(UISwitch *)sw;
+ (void)applyToLabel:(UILabel *)label primary:(BOOL)isPrimary;

#pragma mark - Row helpers (统一构造表单行，避免各 Section 各写一遍)

/// 标准 "标签 + 控件" 一行；label 等宽 130，无尾部填充。
+ (UIStackView *)rowWithLabel:(NSString *)title
                      control:(UIView *)control;

/// "标签 + 控件 + 可选尾部" 一行；trailing 传 nil 时无尾部。
+ (UIStackView *)rowWithLabel:(NSString *)title
                      control:(UIView *)control
                     trailing:(nullable UIView *)trailing;

/// "标签 + slider + 数值 label" 一行；slider/valueLabel 通过 out 参数回写给调用方。
/// slider 已 apply GF 主题；min/max 直接设置；valueLabel 等宽 60、右对齐、等宽字体。
/// 出参用 `* __strong *` 显式声明,允许 caller 直接传 strong ivar 地址 (不会触发
/// ARC `__autoreleasing` write-back 警告/错误)。
+ (UIStackView *)sliderRowWithLabel:(NSString *)title
                                min:(float)minVal
                                max:(float)maxVal
                          outSlider:(UISlider *__strong _Nullable *_Nonnull)outSlider
                      outValueLabel:(UILabel *__strong _Nullable *_Nonnull)outValueLabel;

/// "标签 + slider + 可输入数值框" 一行。跟上面 sliderRowWithLabel 同样, 但右侧是
/// UITextField (decimal pad + Done), 用户可拉 slider 也可直接输入数字。键盘类型默认
/// UIKeyboardTypeDecimalPad, 不接受非数字。caller 自己挂 editingDidEnd / valueChanged。
+ (UIStackView *)sliderRowWithLabel:(NSString *)title
                                min:(float)minVal
                                max:(float)maxVal
                          outSlider:(UISlider *__strong _Nullable *_Nonnull)outSlider
                      outValueField:(UITextField *__strong _Nullable *_Nonnull)outValueField;

/// 轻量 toast 提示: 在 view 所在 window 底部居中弹出一条短消息, 约 1.6s 自动消失。
+ (void)toast:(NSString *)message inView:(UIView *)view;

/// 递归查找视图树中的第一响应者(键盘避让等场景用); 无则 nil。
+ (nullable UIView *)firstResponderIn:(UIView *)view;

/// 秒数 → "m:ss" 显示串; 负数/NaN/Inf 返回 "--:--"。
+ (NSString *)formatTimeMmSs:(double)seconds;

/// 主题进度条: 主题橙 + 半透明白轨道, 初始隐藏(与导出蒙版里的进度条配色一致)。
+ (UIProgressView *)themedProgressView;

/// 官方样式弹框(对齐官方 Modal / 截图 IMG_1447): 半透明蒙层 + 深色圆角卡片, 自上而下
/// 图标(Info=蓝ⓘ / Success=绿✓, 对齐官方 Modal.Info/Success) → 居中多行文案 →
/// 居中「确定」按钮 → 「不再显示」勾选(dontShowAgainKey 非 nil 才显示, 勾选后该 key
/// 持久化进 NSUserDefaults、下次调用直接不弹)。挂 view 所在 window 层(导出蒙版等
/// bringSubviewToFront 也盖不住), 非阻塞。
+ (void)showModalOverView:(UIView *)view
                  message:(NSString *)message
                  success:(BOOL)success
         dontShowAgainKey:(nullable NSString *)dontShowAgainKey;

/// 同上, 但「确定」点击后(或被「不再显示」抑制而不弹时)回调 onConfirm。
/// 用于需要在确定后继续动作的场景(如导出前的"请选择目标文件夹"提示 → 确定 → 打开选择器)。
/// 被抑制时立即同步触发 onConfirm, 保证后续动作不被静默丢弃。
+ (void)showModalOverView:(UIView *)view
                  message:(NSString *)message
                  success:(BOOL)success
         dontShowAgainKey:(nullable NSString *)dontShowAgainKey
                onConfirm:(nullable void (^)(void))onConfirm;

/// 把数值输入框和 slider 双向绑定: 输入框编辑结束时解析(显示值/scale), 夹到 slider
/// 范围后设回 slider 并触发其既有 valueChanged(由既有 handler 写回 model + 重格式化输入框)。
/// scale = 显示值 / slider 值 (绝大多数为 1.0)。slider->输入框 仍由 caller 的 valueChanged 负责。
+ (void)makeField:(UITextField *)field editSlider:(UISlider *)slider scale:(double)scale;

/// UIButton + UIMenu 风格的下拉框 (iOS 14+)。
/// titles: 显示文本数组; selectedIdx: 初始选中索引; onChange: 用户选择变化时回调 (传新 index)。
/// 控件已 apply GF 主题 (副背景 + R4 + 主文本色)。
+ (UIButton *)makeDropdownWithTitles:(NSArray<NSString *> *)titles
                            selected:(NSInteger)selectedIdx
                            onChange:(void(^_Nullable)(NSInteger))onChange;

/// 勾选某功能才显示的子内容: 左侧统一缩进 12px(对 UIStackView 加 leading layoutMargin)。
+ (void)applyRevealIndent:(UIView *)container;
/// 「高级选项」展开内容: 副背景色 + 圆角 + 内边距, 与主背景区分。
+ (void)applyAdvancedExpandStyle:(UIView *)container;

@end

NS_ASSUME_NONNULL_END