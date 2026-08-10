import WebKit
import ObjectiveC

extension WKWebView {
    func removeInputAccessoryView() {
        guard let target = scrollView.subviews.first(where: {
            String(describing: type(of: $0)).hasPrefix("WKContent")
        }), let targetClass = object_getClass(target) else { return }

        let newClassName = String(describing: targetClass) + "_NoInputAccessory"
        var newClass: AnyClass? = NSClassFromString(newClassName)

        if newClass == nil {
            newClass = objc_allocateClassPair(targetClass, newClassName, 0)
            if let newClass {
                let selector = #selector(getter: UIResponder.inputAccessoryView)
                let block: @convention(block) (AnyObject) -> UIView? = { _ in nil }
                let imp = imp_implementationWithBlock(block)
                class_addMethod(newClass, selector, imp, "@@:")
                objc_registerClassPair(newClass)
            }
        }

        if let newClass {
            object_setClass(target, newClass)
        }
    }
}
