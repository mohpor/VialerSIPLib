//
//  VSLTransferInProgressViewController.swift
//  Copyright © 2016 Devhouse Spindle. All rights reserved.
//

import UIKit

private var myContext = 0

class VSLTransferInProgressViewController: UIViewController {

    // MARK: - Configuration

    struct Configuration {
        struct Segues {
            static let UnwindToCallViewController = "UnwindToCallViewControllerSegue"
            static let UnwindToSecondCallViewController = "UnwindToSecondCallViewControllerSegue"
        }
        static let UnwindTiming = 2.0
    }

    // MARK: - Properties

    var firstCall: VSLCall? {
        didSet {
            updateUI()
        }
    }

    var secondCall: VSLCall? {
        didSet {
            updateUI()
        }
    }

    // MARK: - Lifecycle

    override func viewWillAppear(animated: Bool) {
        super.viewWillAppear(animated)
        updateUI()
        firstCall?.addObserver(self, forKeyPath: "transferStatus", options: .New, context: &myContext)
        checkIfViewCanBeDismissed()
    }

    override func viewWillDisappear(animated: Bool) {
        super.viewWillDisappear(animated)
        firstCall?.removeObserver(self, forKeyPath: "transferStatus")
    }

    // MARK: - Outlets

    @IBOutlet weak var firstCallNumberLabel: UILabel!
    @IBOutlet weak var secondCallNumberLabel: UILabel!
    @IBOutlet weak var transferStatusLabel: UILabel!

    // MARK: - Actions

    @IBAction func backButtonPressed(sender: UIBarButtonItem) {
        self.dismissView()
    }

    func updateUI() {
        if let call = firstCall, let label = firstCallNumberLabel, let statusLabel = transferStatusLabel {
            label.text = call.callerNumber!
            switch call.transferStatus {
            case .Unkown: fallthrough
            case .Initialized:
                statusLabel.text = "Transfer requested for"
            case .Trying:
                statusLabel.text = "Transfer in progress to"
            case .Accepted:
                statusLabel.text = "Successfully connected with"
            case .Rejected:
                statusLabel.text = "Transfer rejected for"
            }
        }

        if let call = secondCall, let label = secondCallNumberLabel {
            label.text = call.callerNumber!
        }
    }

    private func prepareForDismissing() {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, Int64(Configuration.UnwindTiming * Double(NSEC_PER_SEC))), dispatch_get_main_queue()) {
            dispatch_async(GlobalMainQueue) {
                self.dismissView()
            }
        }
    }

    private func dismissView() {
        // Rewind one step if transfer was rejected.
        if firstCall?.transferStatus == .Rejected {
            performSegueWithIdentifier(Configuration.Segues.UnwindToSecondCallViewController, sender: nil)
        } else {
            performSegueWithIdentifier(Configuration.Segues.UnwindToCallViewController, sender: nil)
        }
    }

    private func checkIfViewCanBeDismissed() {
        if let call = firstCall where call.transferStatus == .Accepted || call.transferStatus == .Rejected {
            prepareForDismissing()
        }
    }
    // MARK: - KVO

    override func observeValueForKeyPath(keyPath: String?, ofObject object: AnyObject?, change: [String : AnyObject]?, context: UnsafeMutablePointer<Void>) {
        if context == &myContext {
            if keyPath == "transferStatus" {
                dispatch_async(GlobalMainQueue) {
                    self.updateUI()
                }
                checkIfViewCanBeDismissed()
            }
        } else {
            super.observeValueForKeyPath(keyPath, ofObject: object, change: change, context: context)
        }
    }
}
