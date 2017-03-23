//
//  ARAnnotationView.swift
//  HDAugmentedRealityDemo
//
//  Created by Danijel Huis on 23/04/15.
//  Copyright (c) 2015 Danijel Huis. All rights reserved.
//

import UIKit

/// View for annotation. Subclass to customize. Annotation views should be lightweight,
/// try to avoid xibs and autolayout.
open class ARAnnotationView: UIView {
    open weak var annotation: ARAnnotation?
    
    public init() {
        super.init(frame: CGRect.zero)
    }
    
    public required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
    }
    
    override public init(frame: CGRect) {
        super.init(frame: frame)
    }
    
    
}
