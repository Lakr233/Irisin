import Foundation

class RedBlackTreeChildrenUpdater<NodeID: RedBlackTreeNodeID, NodeValue: RedBlackTreeNodeValue, NodeData> {
    typealias Node = RedBlackTreeNode<NodeID, NodeValue, NodeData>

    func updateAfterChangingChildren(of _: Node) -> Bool {
        false
    }
}
