#import <UIKit/UIKit.h>
#import "ParamsModel.h"

NS_ASSUME_NONNULL_BEGIN

/// View - 导出设置区域 (对齐桌面"导出设置"面板):
/// 编解码器 / 输出大小(带锁定宽高比 + 尺寸预设) / 比特率 / 使用 GPU 编码 / 导出音频。
///
/// 输出大小原先在 AdvancedSectionView(高级), 现移到此处。其它几项为导出专用设置,
/// 写入 ParamsModel 的 export* 字段, 由 Controller 在导出时读取(不接 FFI / 不触发 recompute)。
@interface ExportSectionView : UIView
@property (nonatomic, weak, nullable) ParamsModel *model;
@property (nonatomic, assign) CGSize inputSize;  // 视频原生尺寸, 用于"输出大小"预设换算
/// 输出大小行布局: NO(默认)=单行(标签+控件同一行, 竖屏); YES=两行(标签上/控件下, 横屏窄列)。
@property (nonatomic, assign) BOOL sizeRowStacked;
/// 输出大小校验结果变化(对齐官方 canExport, Export.qml:117): 超所选编码器最大分辨率
/// 时 valid=NO, Controller 据此禁用「导出」按钮。
@property (nonatomic, copy, nullable) void(^onResolutionValidChanged)(BOOL valid);

/// 输出路径(对齐官方导出页顶部 OutputPathField): 当前输出文件名(用户可编辑)。
/// 空白时返回 nil, Controller 用兜底名。
@property (nonatomic, readonly, nullable) NSString *outputFileName;
/// 视频加载时设置默认输出文件名(对齐官方 VideoArea.qml:438 每次加载重置:
/// 视频名 + "_stabilized" + 扩展名)。
- (void)setDefaultOutputFileName:(NSString *)name;

/// 把 Controller 的「导出」按钮嵌入本卡片(输出路径行之下, 对齐官方布局顺序:
/// 输出路径 → 导出按钮 → 编解码器 → 输出大小 → 比特率 → 音频)。只需调用一次。
- (void)embedExportButton:(UIButton *)button;

/// 输出路径行尾「…」按钮点击(对齐官方目录选择): Controller 弹系统目录选择器,
/// 选定后导出产物写入该目录。
@property (nonatomic, copy, nullable) void(^onPickExportFolder)(void);

/// 在「输出路径:」标签同一行显示当前导出目标目录。path 为 nil/空 → 显示「未选择」。
/// 授权/恢复/换目录后由 Controller 调用。
- (void)setExportFolderDisplay:(nullable NSString *)path;

/// 输出文件名编辑提交(失焦/回车)。Controller 对目标目录查重: 已有同名 → 自增 _X
/// 回写输入框; 无同名保持用户输入。
@property (nonatomic, copy, nullable) void(^onOutputFileNameEdited)(void);
/// 输出文件名实时变化(每次按键, 已剥路径前缀)。Controller 据此实时刷新「导出」
/// 按钮可用态(对齐官方 filename.length > 3 才可导出)。
@property (nonatomic, copy, nullable) void(^onOutputFileNameChanged)(void);
/// recompute / 镜头档案加载后, outputSize 可能被外部改动, 刷新输出大小输入框显示。
- (void)refreshReadOnly;
@end

NS_ASSUME_NONNULL_END
