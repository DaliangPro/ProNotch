import XCTest
@testable import ProNotch

/// 模型展示名映射（任务书 §10.2.1）：界面上不再直接甩接口 slug，
/// 但 slug 仍是数据层唯一标识，只在展示层转换
final class ModelDisplayNameTests: XCTestCase {

    func test厂商与版本号规范化() {
        XCTAssertEqual(ModelDisplayName.of("deepseek-v4-pro"), "DeepSeek V4 Pro")
        XCTAssertEqual(ModelDisplayName.of("deepseek-v4-flash"), "DeepSeek V4 Flash")
        XCTAssertEqual(ModelDisplayName.of("kimi-k2-turbo"), "Kimi K2 Turbo")
        XCTAssertEqual(ModelDisplayName.of("glm-4-air"), "GLM 4 Air")
    }

    func test带命名空间的只取最后一段() {
        XCTAssertEqual(ModelDisplayName.of("anthropic/claude-sonnet"), "Claude Sonnet")
    }

    func test下划线也当分隔符() {
        XCTAssertEqual(ModelDisplayName.of("qwen_max"), "Qwen Max")
    }

    /// 认不出的段落原样保留：宁可显示 slug，也不显示猜错的名字
    func test认不出的原样保留() {
        XCTAssertEqual(ModelDisplayName.of("acme-x9"), "Acme X9")
        XCTAssertEqual(ModelDisplayName.of("20241022"), "20241022")
    }

    func test空串与空白() {
        XCTAssertEqual(ModelDisplayName.of(""), "")
        XCTAssertEqual(ModelDisplayName.of("   "), "")
    }

    func test中文厂商() {
        XCTAssertEqual(ModelDisplayName.of("doubao-pro"), "豆包 Pro")
    }
}
