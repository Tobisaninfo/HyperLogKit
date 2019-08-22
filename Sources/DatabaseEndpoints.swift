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

public class LXDataBaseEndpoint{
    
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
    
    func createData(){
        let managedContext = persistentContainer.viewContext
        let logEntity = NSEntityDescription.entity(forEntityName: "Logs", in: managedContext)!
        let user = NSManagedObject(entity: logEntity, insertInto: managedContext)
        let currentTime = round(NSDate().timeIntervalSince1970 * 1000)
        user.setValue(currentTime, forKey: "timeStamp")
        user.setValue("TESTING CORE DATA", forKey: "message")
        user.setValue(false, forKey: "sent")

        do {
            try managedContext.save()
            
        } catch let error as NSError {
            print("Could not save. \(error), \(error.userInfo)")
        }
    }
    
    func DeleteAllData(){
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
                print(data.value(forKey: "timeStamp") as! Int32)
                print(data.value(forKey: "message") as! String)
                print(data.value(forKey: "sent") as! Bool)
            }
            
        } catch {
            
            print("Failed")
        }
        
    }
}
