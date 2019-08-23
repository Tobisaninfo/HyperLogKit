// DatabaseEndpoints.swift
//
// Copyright (c) 2015 - 2016, Kasiel Solutions Inc. & The LogKit Project
// http://www.logkit.info/
//
// Permission to use, copy, modify, and/or distribute this software for any
// purpose with or without fee is hereby granted, provided that the above
// copyright notice and this permission notice appear in all copies.
//
// THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
// WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
// MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
// ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
// WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
// ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
// OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

import Foundation
import CoreData

private protocol LXDBWriter {
    func writeData(data: Data) -> Void
}

struct Constants {
    static let daysToSave = 7
    static let daysToSaveInMil = Double(daysToSave * 24 * 60 * 60 * 1000)
}

public class LXDataBaseEndpoint: LXEndpoint {
    
    /// The minimum Priority Level a Log Entry must meet to be accepted by this Endpoint.
    public var minimumPriorityLevel: LXPriorityLevel
    /// The formatter used by this Endpoint to serialize a Log Entry’s `dateTime` property to a string.
    public var dateFormatter: LXDateFormatter
    /// The formatter used by this Endpoint to serialize each Log Entry to a string.
    public var entryFormatter: LXEntryFormatter
    /// This Endpoint requires a newline character appended to each serialized Log Entry string.
    public let requiresNewlines: Bool = true
    
    private let writer: LXDBWriter
    
    lazy var persistentContainer: NSPersistentContainer = {
        let messageKitBundle = Bundle(identifier: "info.logkit.LogKit")
        let modelURL = messageKitBundle!.url(forResource: "LogKit", withExtension: "momd")
        let managedObjectModel = NSManagedObjectModel(contentsOf: modelURL!)
        let container = NSPersistentContainer(name: "LogKit", managedObjectModel: managedObjectModel!)
 
        container.loadPersistentStores(completionHandler: { (storeDescription, error) in
            if let error = error as NSError? {
                //Replace fatalError
                fatalError("Unresolved error \(error), \(error.userInfo)")
            }
        })
        return container
    }()
    
    func saveContext () {
        let context = persistentContainer.viewContext
        if context.hasChanges {
            do {
                try context.save()
            } catch {
                let nserror = error as NSError
                //Replace fatalError
                fatalError("Unresolved error \(nserror), \(nserror.userInfo)")
            }
        }
    }
    
    func createData(data: Data){
        let managedContext = persistentContainer.viewContext
        
        //Trimming DB if it has older than "predicatedTimeStamp"
        let currentTime = round(NSDate().timeIntervalSince1970 * 1000)
        let predicatedTimeStamp:Double = currentTime - Constants.daysToSaveInMil
        let requestDel = NSFetchRequest<NSFetchRequestResult>(entityName: "Logs")
        let predicateDel = NSPredicate(format: "timeStamp < %d", argumentArray: [predicatedTimeStamp])
        requestDel.predicate = predicateDel
   
        do {
            let arrLogsObj = try managedContext.fetch(requestDel)
            for logObj in arrLogsObj as! [NSManagedObject] {
                managedContext.delete(logObj)
            }
        } catch {
            print("Failed")
        }
        do {
            try managedContext.save()
        } catch {
            print("Failed saving")
        }
        
        //Inserting new log into DB
        let logEntity = NSEntityDescription.entity(forEntityName: "Logs", in: managedContext)!
        let log = NSManagedObject(entity: logEntity, insertInto: managedContext)
        let logMsg = String(decoding: data, as: UTF8.self)
        log.setValue(currentTime, forKey: "timeStamp")
        log.setValue(logMsg, forKey: "message")
        log.setValue(false, forKey: "sent")
        
        //Check the current contents of Logs Database
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: "Logs")
        request.returnsObjectsAsFaults = false
        do {
            let result = try managedContext.fetch(request)
            for data in result as! [NSManagedObject] {
                print(data.value(forKey: "timeStamp") as! Double)
                print(data.value(forKey: "message") as! String)
                print(data.value(forKey: "sent") as! Bool)
            }
            
        } catch {
            
            print("Failed")
        }

        do {
            try managedContext.save()
            
        } catch let error as NSError {
            print("Could not save. \(error), \(error.userInfo)")
        }
    }
    
    //changing the sent flag once it's been sent to the server
    func updateData() {
        let managedContext = persistentContainer.viewContext
        let fetchRequest:NSFetchRequest<NSFetchRequestResult> = NSFetchRequest.init(entityName: "Logs")
        fetchRequest.predicate = NSPredicate(format: "sent = %@", "false")
        
        do {
            let flagDown = try managedContext.fetch(fetchRequest)
            let objectUpdate = flagDown[0] as! NSManagedObject
            objectUpdate.setValue(true, forKey: "sent")
            
            do {
                try managedContext.save()
            }
            catch {
                print(error)
            }
        }
        catch {
            print(error)
        }
    }
    
    func deleteAllData(){
        let managedContext = persistentContainer.viewContext
        let DelAllReqVar = NSBatchDeleteRequest(fetchRequest: NSFetchRequest<NSFetchRequestResult>(entityName: "Logs"))
        do {
            try managedContext.execute(DelAllReqVar)
        }
        catch {
            print(error)
        }
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: "Logs")
        request.returnsObjectsAsFaults = false
        
        do {
            let result = try managedContext.fetch(request)
            for data in result as! [NSManagedObject] {
                print(data.value(forKey: "timeStamp") as! Double)
                print(data.value(forKey: "message") as! String)
                print(data.value(forKey: "sent") as! Bool)
            }
            
        } catch {
            
            print("Failed")
        }
        
    }
    
    public init(
        synchronous: Bool = false,
        minimumPriorityLevel: LXPriorityLevel = .All,
        dateFormatter: LXDateFormatter = LXDateFormatter.standardFormatter(),
        entryFormatter: LXEntryFormatter = LXEntryFormatter.standardFormatter()
        ) {
        self.minimumPriorityLevel = minimumPriorityLevel
        self.dateFormatter = dateFormatter
        self.entryFormatter = entryFormatter

        switch synchronous {
        case true:
            self.writer = LXSynchronousDBWriter()
        case false:
            self.writer = LXAsynchronousDBWriter()
        }
    }

    // Writes a serialized Log Entry string to the console (`stderr`).
    public func write(string: String) {
        guard let data = string.data(using: String.Encoding.utf8) else {
            assertionFailure("Failure to create data from entry string")
            return
        }
        LK_LOGKIT_QUEUE.async {
            self.createData(data: data)
        }
    }
}

//MARK: DataBase Writers

// A private console writer that facilitates synchronous output.
private class LXSynchronousDBWriter: LXDBWriter {

    /// The console's (`stderr`) file handle.
    fileprivate let handle = FileHandle.standardError

    /// Clean up.
    deinit { self.handle.closeFile() }

    /// Writes the data to the console (`stderr`).
    fileprivate func writeData(data: Data) {
        self.handle.write(data)
    }

}


// A private console writer that facilitates asynchronous output.
private class LXAsynchronousDBWriter: LXSynchronousDBWriter{
//    TODO: open a dispatch IO channel to stderr instead of one-off writes?
    /// Writes the data to the console (`stderr`).
    fileprivate override func writeData(data: Data) {
        LK_LOGKIT_QUEUE.async {
            self.handle.write(data)
        }
    }

}

